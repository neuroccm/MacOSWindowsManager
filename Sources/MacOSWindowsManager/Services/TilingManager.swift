import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class TilingManager: ObservableObject {
    @Published public private(set) var lastWindowCount: Int = 0
    @Published public private(set) var lastStatus: String = "Idle"
    @Published public private(set) var isOverview: Bool = true

    public let settings: SettingsStore
    private var originalFrames: [CGWindowID: CGRect] = [:]
    private var animationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// One fractal tree + one camera per display (key = displayKey).
    public private(set) var trees: [String: LayoutNode] = [:]
    public private(set) var cameras: [String: CameraState] = [:]
    public private(set) var savedStore = SavedViewStore()
    public private(set) var lastManaged: [ManagedWindow] = []
    private let savedKey = "savedViewsPerDisplay.v1"

    /// Stable planner memory per display: reading order from the last plan.
    /// This is what prevents reshuffling — survivors keep their slots.
    private var stableOrder: [String: [UInt32]] = [:]
    private var stableTabHosts: [String: [UInt32: UInt32]] = [:]
    /// Fingerprint of the window set last laid out. Retiles triggered by
    /// workspace noise (activations, focus clicks) compare against this and
    /// become no-ops unless a window actually opened/closed/moved display.
    private var lastFingerprint: String = ""
    private var lastLayoutMode: LayoutMode?

    public init(settings: SettingsStore) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: savedKey),
           let decoded = try? JSONDecoder().decode([String: [String: [String: CodableRect]]].self, from: data) {
            for (disp, slots) in decoded {
                for (slotStr, frames) in slots {
                    if let slot = Int(slotStr) {
                        savedStore.byDisplay[disp, default: [:]][slot] = frames.mapKeys { UInt32($0) ?? 0 }
                    }
                }
            }
        }
        // Re-encode shape note: persistence uses UInt32 keys via CodableRect dict below in persistSaved().
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    public static func displayKey(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(num.uint32Value)"
        }
        return "display-\(screen.localizedName)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    private func screen(forAXFrame f: CGRect) -> NSScreen? {
        let c = CoordinateConverter.cocoaPoint(fromAX: CGPoint(x: f.midX, y: f.midY), primaryHeight: primaryHeight)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func screen(forCocoaPoint p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    public func windows() -> [ManagedWindow] { AXWindowService.allWindows(excludedBundleIDs: settings.excludedBundleIDs) }

    private func camera(for key: String, screen: NSScreen) -> CameraState {
        if let c = cameras[key] { return c }
        let c = CameraState(viewport: screen.visibleFrame)
        cameras[key] = c; return c
    }

    // MARK: - Tree sync & tiling

    private func syncTree(ids: [UInt32], key: String) -> LayoutNode {
        var tree = trees[key] ?? LayoutNode.balanced(ids: ids) ?? .leaf(id: ids.first ?? 0)
        for dead in tree.leafIDs where !ids.contains(dead) { tree = tree.removing(dead) ?? tree }
        // If tree collapsed to nil-equivalent (empty), rebuild.
        if tree.leafIDs.isEmpty, let f = ids.first { tree = .leaf(id: f) }
        for id in ids where !tree.leafIDs.contains(id) {
            tree = tree.inserting(id, targetID: tree.leafIDs.last)
        }
        trees[key] = tree
        return tree
    }

    private func groupByDisplay(_ all: [ManagedWindow]) -> [String: (NSScreen, [ManagedWindow])] {
        var byScreen: [String: (NSScreen, [ManagedWindow])] = [:]
        for w in all { if let s = screen(forAXFrame: w.snapshot.axFrame) { byScreen[Self.displayKey(for: s), default: (s, [])].1.append(w) } }
        return byScreen
    }

    private func fingerprint(of byScreen: [String: (NSScreen, [ManagedWindow])]) -> String {
        let screens = NSScreen.screens.map { "\(Int($0.visibleFrame.width))x\(Int($0.visibleFrame.height))@\(Int($0.visibleFrame.minX)),\(Int($0.visibleFrame.minY))" }.joined(separator: ";")
        let sets = byScreen.sorted { $0.key < $1.key }
            .map { "\($0.key):" + $0.value.1.map { String($0.snapshot.windowID) }.sorted().joined(separator: ",") }
            .joined(separator: "|")
        return screens + "#" + sets
    }

    /// Workspace-notification path: lays out ONLY if the window set (or a
    /// display) actually changed. Clicking between windows must never
    /// rearrange anything.
    public func tileAllIfWindowSetChanged() {
        // Never plan against the Mission Control canvas: frames and
        // on-screen membership there do not reflect the real Space.
        guard !AXWindowService.isSystemOverviewActive() else { return }
        guard AXWindowService.isAccessibilityTrusted(prompt: false) else { return }
        let all = windows()
        let byScreen = groupByDisplay(all)
        if fingerprint(of: byScreen) == lastFingerprint, lastLayoutMode == settings.layoutMode {
            lastManaged = all // refresh snapshots, move nothing
            return
        }
        tile(all: all, byScreen: byScreen, animated: true)
    }

    public func tileAll(animated: Bool = true) {
        guard AXWindowService.isAccessibilityTrusted(prompt: false) else { lastStatus = "Accessibility permission needed"; return }
        let all = windows()
        tile(all: all, byScreen: groupByDisplay(all), animated: animated)
    }

    private func tile(all: [ManagedWindow], byScreen: [String: (NSScreen, [ManagedWindow])], animated: Bool) {
        if AXWindowService.isSystemOverviewActive() {
            lastStatus = "Mission Control is showing — tiling paused until it closes"
            return
        }
        lastManaged = all
        lastWindowCount = all.count
        if lastLayoutMode != settings.layoutMode {
            // Mode switched: re-seed the stable order from scratch (focused
            // primary + pairing) instead of carrying another mode's order.
            lastLayoutMode = settings.layoutMode
            stableOrder.removeAll(); stableTabHosts.removeAll()
        }
        lastFingerprint = fingerprint(of: byScreen)
        guard !all.isEmpty else { lastStatus = "No standard windows found"; return }
        for w in all where originalFrames[w.snapshot.windowID] == nil { originalFrames[w.snapshot.windowID] = w.snapshot.axFrame }
        if originalFrames.count > 64 { // prune frames of long-closed windows
            let live = Set(AXWindowService.allWindows(excludedBundleIDs: [], onScreenOnly: false).map { $0.snapshot.windowID })
            originalFrames = originalFrames.filter { live.contains($0.key) }
        }
        var targets: [CGWindowID: (ManagedWindow, CGRect)] = [:]
        for (key, (scr, group)) in byScreen {
            let cam = camera(for: key, screen: scr)
            if let zid = cam.zoomedWindowID, group.contains(where: { $0.snapshot.windowID == zid }) {
                // Zoomed: focused window fills the display, others keep last frames.
                for w in group where w.snapshot.windowID == zid {
                    targets[w.snapshot.windowID] = (w, CoordinateConverter.axFrame(fromCocoa: scr.visibleFrame, primaryHeight: primaryHeight))
                }
                continue
            }
            let frames = framesFor(group: group, screen: scr, key: key)
            for w in group { if let cf = frames[w.snapshot.windowID] { targets[w.snapshot.windowID] = (w, CoordinateConverter.axFrame(fromCocoa: cf, primaryHeight: primaryHeight)) } }
        }
        apply(targets: targets, animated: animated)
        raiseFocusedIfTabbed(among: all)
        isOverview = cameras.values.allSatisfy { $0.isOverview }
        let tabbed = settings.layoutMode == .stable ? stableTabHosts.values.reduce(0) { $0 + $1.count } : 0
        lastStatus = "Tiled \(all.count) window(s) across \(byScreen.count) display(s)"
            + (tabbed > 0 ? " · \(tabbed) tabbed behind tiles" : "")
    }

    /// A tabbed window the user just focused/raised must sit on top of the
    /// tile it shares — raise only, never activate (no focus stealing).
    private func raiseFocusedIfTabbed(among all: [ManagedWindow]) {
        guard let fid = AXWindowService.focusedWindowID(),
              stableTabHosts.values.contains(where: { $0[fid] != nil }),
              let w = all.first(where: { $0.snapshot.windowID == fid }) else { return }
        AXWindowService.raise(w)
    }

    private func framesFor(group: [ManagedWindow], screen scr: NSScreen, key: String) -> [UInt32: CGRect] {
        let ids = group.map { $0.snapshot.windowID }
        if settings.layoutMode == .stable {
            let focusedID = AXWindowService.focusedWindowID()
            let inputs = group.map { w in
                StableWindowInput(
                    id: w.snapshot.windowID, bundleID: w.snapshot.bundleID, appName: w.snapshot.appName,
                    isFocused: w.snapshot.windowID == focusedID,
                    currentFrame: CoordinateConverter.cocoaFrame(fromAX: w.snapshot.axFrame, primaryHeight: primaryHeight))
            }
            let plan = StableLayout.plan(windows: inputs, previousOrder: stableOrder[key] ?? [],
                                         in: scr.visibleFrame, gap: CGFloat(settings.gap))
            stableOrder[key] = plan.orderedIDs
            stableTabHosts[key] = plan.tabbedBehind
            return plan.frames
        }
        if settings.layoutMode == .bsp {
            let tree = syncTree(ids: ids, key: key)
            return tree.frames(in: scr.visibleFrame, gap: CGFloat(settings.gap))
        }
        return LayoutEngine.frames(ids: ids, in: scr.visibleFrame, gap: CGFloat(settings.gap), mode: settings.layoutMode, masterRatio: settings.masterRatio)
    }

    /// Re-apply one display's tree after a dock / seam / tab mutation.
    public func retileDisplay(key: String, animated: Bool = false) {
        guard let scr = NSScreen.screens.first(where: { Self.displayKey(for: $0) == key }) else { tileAll(animated: animated); return }
        let group = lastManaged.filter { w in (screen(forAXFrame: w.snapshot.axFrame).map { Self.displayKey(for: $0) } ?? "") == key }
        guard !group.isEmpty else { tileAll(animated: animated); return }
        var targets: [CGWindowID: (ManagedWindow, CGRect)] = [:]
        let frames = framesFor(group: group, screen: scr, key: key)
        for w in group { if let cf = frames[w.snapshot.windowID] { targets[w.snapshot.windowID] = (w, CoordinateConverter.axFrame(fromCocoa: cf, primaryHeight: primaryHeight)) } }
        apply(targets: targets, animated: animated)
        raiseActiveTabs(in: group)
    }

    private func raiseActiveTabs(in group: [ManagedWindow]) {
        for (_, tree) in trees {
            func walk(_ n: LayoutNode) {
                if case .tabs(let ids, let a) = n, ids.indices.contains(a) {
                    // Raise only: focus() would activate the app, steal the
                    // user's focus, and retrigger a workspace retile.
                    if let w = group.first(where: { $0.snapshot.windowID == ids[a] }) { AXWindowService.raise(w) }
                }
                if case .split(_, _, let x, let y) = n { walk(x); walk(y) }
            }
            walk(tree)
        }
    }

    private func apply(targets: [CGWindowID: (ManagedWindow, CGRect)], animated: Bool) {
        animationTask?.cancel()
        if !animated { for (_, (w, f)) in targets { AXWindowService.setFrame(f, on: w.element) }; return }
        let starts: [CGWindowID: CGRect] = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0.value.0.snapshot.axFrame) })
        // Skip windows already (essentially) at target: no AX traffic, no redraw.
        let moving = targets.filter { id, pair in
            starts[id].map { AnimationTiming.framesDiffer($0, pair.1) } ?? true
        }
        guard !moving.isEmpty else { return }
        animationTask = Task { @MainActor in
            // Deadline-paced, not sleep-after-work: each frame is computed from elapsed
            // wall time, so a slow app can't stretch the schedule or bunch up steps.
            let clock = ContinuousClock()
            let start = clock.now
            let duration = AnimationTiming.duration
            var lastSent: [CGWindowID: CGRect] = starts
            while true {
                if Task.isCancelled { return }
                let dur = start.duration(to: clock.now)
                let elapsed = Double(dur.components.seconds) + Double(dur.components.attoseconds) / 1e18
                let t = min(elapsed / duration, 1)
                for (id, (w, target)) in moving {
                    guard let s = starts[id] else { continue }
                    let f = AnimationTiming.easedFrame(from: s, to: target, t: t).integral
                    if let prev = lastSent[id], !AnimationTiming.framesDiffer(prev, f, tolerance: 0.5) && t < 1 { continue }
                    AXWindowService.setFrame(f, on: w.element, from: lastSent[id])
                    lastSent[id] = f
                }
                if t >= 1 { break }
                // Sleep only until the next 60fps frame boundary.
                let intoFrame = elapsed.truncatingRemainder(dividingBy: AnimationTiming.frameInterval)
                let wait = max(AnimationTiming.frameInterval - intoFrame, 0.002)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: - Float / maximize / focus (v1, preserved)

    public func floatAll() {
        animationTask?.cancel()
        // Restore covers every Space, not just the visible one.
        for w in AXWindowService.allWindows(excludedBundleIDs: [], onScreenOnly: false) {
            if let o = originalFrames[w.snapshot.windowID] { AXWindowService.setFrame(o, on: w.element) }
        }
        lastStatus = "Floated all windows (original positions restored)"
    }
    public func restoreOnQuit() { floatAll() }

    public func maximizeFocused() {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs), let scr = screen(forAXFrame: f.snapshot.axFrame) else { return }
        zoomIn(windowID: f.snapshot.windowID, screen: scr)
    }

    public func cycleFocus(forward: Bool) {
        let all = windows(); guard !all.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let idx = all.firstIndex { $0.snapshot.pid == front } ?? -1
        let n = forward ? all[(idx + 1 + all.count) % all.count] : all[(idx - 1 + all.count) % all.count]
        AXWindowService.focus(n); lastStatus = "Focused \(n.snapshot.appName)"
    }

    public func moveFocusedToNextDisplay() {
        guard NSScreen.screens.count > 1, let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs),
              let cur = screen(forAXFrame: f.snapshot.axFrame), let i = NSScreen.screens.firstIndex(of: cur) else {
            lastStatus = NSScreen.screens.count > 1 ? "No focused window" : "Only one display connected"
            return
        }
        let next = NSScreen.screens[(i + 1) % NSScreen.screens.count]
        if originalFrames[f.snapshot.windowID] == nil { originalFrames[f.snapshot.windowID] = f.snapshot.axFrame }
        // Re-parent: remove from old tree/order; on the target display the
        // window is a newcomer and takes that display's next stable slot.
        let oldKey = Self.displayKey(for: cur), newKey = Self.displayKey(for: next)
        if let t = trees[oldKey] { trees[oldKey] = t.removing(f.snapshot.windowID) }
        if var t = trees[newKey] { trees[newKey] = t.inserting(f.snapshot.windowID, targetID: t.leafIDs.last) }
        stableOrder[oldKey]?.removeAll { $0 == f.snapshot.windowID }
        lastFingerprint = "" // force the scheduled pass to lay out
        AXWindowService.setFrame(CoordinateConverter.axFrame(fromCocoa: next.visibleFrame, primaryHeight: primaryHeight), on: f.element)
        if settings.isTilingEnabled { scheduleRetile() }
        lastStatus = "Moved to \(next.localizedName)"
    }

    // MARK: - Drag-to-dock / tabs / seams

    /// Dock a dragged window onto a target window (center = tab) or a screen edge.
    public func dock(draggedID: CGWindowID, targetID: CGWindowID?, zone: DockZone, atCocoaPoint point: CGPoint) {
        guard let scr = screen(forCocoaPoint: point) else { return }
        let key = Self.displayKey(for: scr)
        let all = windows(); lastManaged = all
        let ids = all.filter { screen(forAXFrame: $0.snapshot.axFrame) == scr }.map { $0.snapshot.windowID }
        var tree = syncTree(ids: ids.filter { $0 != draggedID } + (ids.contains(draggedID) ? [] : []), key: key)
        // Remove dragged from wherever it was, then dock it.
        tree = tree.removing(draggedID) ?? tree
        if tree.leafIDs.isEmpty, let other = ids.first(where: { $0 != draggedID }) { tree = .leaf(id: other) }
        if let targetID, targetID != draggedID, tree.leafIDs.contains(targetID) {
            tree = tree.docking(draggedID, on: targetID, zone: zone)
            lastStatus = zone == .center ? "Tabbed window onto \(targetID)" : "Docked \(zone.rawValue) of window"
        } else {
            // Screen edge: dock beside everything on this display.
            let rootTarget = tree.leafIDs.first ?? draggedID
            if tree.leafIDs.contains(rootTarget), rootTarget != draggedID {
                tree = tree.docking(draggedID, on: rootTarget, zone: zone == .center ? .right : zone)
            } else { tree = .leaf(id: draggedID) }
            lastStatus = "Docked to \(zone.rawValue) edge of \(scr.localizedName)"
        }
        trees[key] = tree
        settings.layoutMode = .bsp
        retileDisplay(key: key)
    }

    public func cycleTab(forward: Bool) {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs),
              let scr = screen(forAXFrame: f.snapshot.axFrame) else { return }
        let key = Self.displayKey(for: scr)
        guard var tree = trees[key] else { return }
        tree = tree.cyclingTab(containing: f.snapshot.windowID, forward: forward)
        trees[key] = tree; retileDisplay(key: key); raiseActiveTabs(in: lastManaged)
        lastStatus = "Switched tab"
    }

    public func tearOffFocused() {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs),
              let scr = screen(forAXFrame: f.snapshot.axFrame) else { return }
        let key = Self.displayKey(for: scr)
        guard var tree = trees[key] else { return }
        tree = tree.tearingOff(f.snapshot.windowID)
        trees[key] = tree; retileDisplay(key: key)
        lastStatus = "Tore tab off into its own tile"
    }

    /// Seam resize: delta is a ratio shift (e.g. ±0.05 from a drag or ⌃⌥+/−).
    public func resizeSeam(containing id: CGWindowID, delta: Double) {
        for (key, tree) in trees where tree.leafIDs.contains(id) {
            trees[key] = tree.adjustingSeam(containing: id, delta: delta)
            retileDisplay(key: key)
            lastStatus = "Resized seam (\(delta > 0 ? "+" : "")\(String(format: "%.2f", delta)))"
            return
        }
        // No tree yet (non-BSP mode): fall back to tiling in BSP so the seam exists.
        settings.layoutMode = .bsp; tileAll(animated: false)
    }
    public func resizeFocusedSeam(delta: Double) {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs) else { return }
        if trees.isEmpty { tileAll(animated: false) }
        resizeSeam(containing: f.snapshot.windowID, delta: delta)
    }

    public func seamRectsCocoa() -> [(key: String, rect: CGRect)] {
        var out: [(String, CGRect)] = []
        for scr in NSScreen.screens {
            let key = Self.displayKey(for: scr)
            guard let tree = trees[key] else { continue }
            for r in tree.seamRects(in: scr.visibleFrame, gap: CGFloat(settings.gap)) { out.append((key, r)) }
        }
        return out
    }
    /// Fresh frame for one window (used to confirm a drag really moved
    /// a window in the real Space before docking it).
    public func currentCocoaFrame(of id: CGWindowID) -> CGRect? {
        windows().first { $0.snapshot.windowID == id }
            .map { CoordinateConverter.cocoaFrame(fromAX: $0.snapshot.axFrame, primaryHeight: primaryHeight) }
    }

    /// Window frames in true front-to-back z-order (AX enumeration order
    /// is arbitrary, so hit-testing must not rely on it).
    public func windowCocoaFrames() -> [(id: CGWindowID, rect: CGRect)] {
        let z = AXWindowService.onScreenWindowIDsInZOrder()
        let rank = Dictionary(uniqueKeysWithValues: z.enumerated().map { ($0.element, $0.offset) })
        return windows()
            .sorted { (rank[$0.snapshot.windowID] ?? Int.max) < (rank[$1.snapshot.windowID] ?? Int.max) }
            .map { w in (w.snapshot.windowID, CoordinateConverter.cocoaFrame(fromAX: w.snapshot.axFrame, primaryHeight: primaryHeight)) }
    }

    // MARK: - Zoom / overview / history

    public func showOverview() {
        for scr in NSScreen.screens {
            let key = Self.displayKey(for: scr)
            var cam = camera(for: key, screen: scr); cam.showOverview(displayRect: scr.visibleFrame); cameras[key] = cam
        }
        isOverview = true; tileAll(); lastStatus = "Overview: everything on every display"
    }

    public func zoomInFocused() {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs) else { return }
        if let scr = screen(forAXFrame: f.snapshot.axFrame) { zoomIn(windowID: f.snapshot.windowID, screen: scr) }
    }
    private func zoomIn(windowID: CGWindowID, screen scr: NSScreen) {
        let key = Self.displayKey(for: scr)
        var cam = camera(for: key, screen: scr)
        let cocoa = CoordinateConverter.cocoaFrame(fromAX: (lastManaged.first { $0.snapshot.windowID == windowID }?.snapshot.axFrame ?? .zero), primaryHeight: primaryHeight)
        cam.zoom(to: cocoa == .zero ? scr.visibleFrame : cocoa, windowID: windowID); cameras[key] = cam
        isOverview = false; tileAll(); lastStatus = "Zoomed into window \(windowID)"
    }
    public func zoomOut() {
        guard let f = AXWindowService.focusedWindow(excludedBundleIDs: settings.excludedBundleIDs),
              let scr = screen(forAXFrame: f.snapshot.axFrame) else { showOverview(); return }
        let key = Self.displayKey(for: scr)
        var cam = camera(for: key, screen: scr); cam.stepOut(displayRect: scr.visibleFrame); cameras[key] = cam
        isOverview = cameras.values.allSatisfy { $0.isOverview }; tileAll(); lastStatus = "Stepped out to overview"
    }
    public func goBack() {
        for scr in NSScreen.screens { let k = Self.displayKey(for: scr); if var c = cameras[k], c.goBack() { cameras[k] = c } }
        isOverview = cameras.values.allSatisfy { $0.isOverview }; tileAll(); lastStatus = "Back"
    }
    public func goForward() {
        for scr in NSScreen.screens { let k = Self.displayKey(for: scr); if var c = cameras[k], c.goForward() { cameras[k] = c } }
        isOverview = cameras.values.allSatisfy { $0.isOverview }; tileAll(); lastStatus = "Forward"
    }

    // MARK: - Saved views (per display, persisted)

    public func saveView(slot: Int) {
        let all = windows()
        var byDisplay: [String: [ManagedWindow]] = [:]
        for w in all { if let s = screen(forAXFrame: w.snapshot.axFrame) { byDisplay[Self.displayKey(for: s), default: []].append(w) } }
        for (key, group) in byDisplay { savedStore.save(display: key, slot: slot, frames: Dictionary(uniqueKeysWithValues: group.map { ($0.snapshot.windowID, $0.snapshot.axFrame) })) }
        persistSaved(); lastStatus = "Saved view \(slot) per display"
    }
    public func restoreView(slot: Int) {
        let all = windows(); var applied = 0
        for w in all {
            guard let s = screen(forAXFrame: w.snapshot.axFrame), let frames = savedStore.frames(display: Self.displayKey(for: s), slot: slot),
                  let f = frames[w.snapshot.windowID] else { continue }
            AXWindowService.setFrame(f, on: w.element); applied += 1
        }
        lastStatus = applied > 0 ? "Restored view \(slot)" : "No saved view \(slot)"
    }
    private func persistSaved() {
        // JSON with string keys at every level for stability.
        var raw: [String: [String: [String: CodableRect]]] = [:]
        for (disp, slots) in savedStore.byDisplay {
            raw[disp] = slots.reduce(into: [:]) { acc, kv in acc[String(kv.key)] = kv.value.reduce(into: [:]) { a, f in a[String(f.key)] = f.value } }
        }
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: savedKey) }
    }

    /// Debounced auto-retile. Runs through the window-set fingerprint, so
    /// bursts of workspace notifications (app activations in particular)
    /// cost one enumeration and move nothing unless a window opened,
    /// closed, or changed display. `force` is for explicit user actions.
    public func scheduleRetile(force: Bool = false) {
        guard settings.isTilingEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            // A retile requested while Mission Control is up waits for it
            // to close (bounded), instead of planning against thumbnails.
            var waits = 0
            while AXWindowService.isSystemOverviewActive(), waits < 20 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                waits += 1
            }
            if Task.isCancelled || AXWindowService.isSystemOverviewActive() { return }
            if force { self.tileAll() } else { self.tileAllIfWindowSetChanged() }
        }
    }

    /// Called when the active Space changes (including returning from
    /// Mission Control to a different desktop). The newly visible window
    /// set becomes the baseline as-is: arriving on a Space never counts
    /// as "windows changed", so nothing rearranges just for looking.
    /// Windows that open or close afterwards tile normally.
    public func adoptCurrentSpaceAsBaseline() {
        guard AXWindowService.isAccessibilityTrusted(prompt: false),
              !AXWindowService.isSystemOverviewActive() else { return }
        let all = windows()
        lastManaged = all
        lastWindowCount = all.count
        lastFingerprint = fingerprint(of: groupByDisplay(all))
        lastLayoutMode = settings.layoutMode
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
