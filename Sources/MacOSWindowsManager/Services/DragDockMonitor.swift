import AppKit
import ApplicationServices

/// Floating dock-preview overlay (never intercepts mouse events).
@MainActor
final class DockOverlay {
    private var window: NSWindow?
    func show(rect: CGRect, tab: Bool) {
        if window == nil {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
            w.level = .floating; w.hasShadow = false
            let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
            v.wantsLayer = true
            w.contentView = v
            window = w
        }
        guard let w = window, let v = w.contentView else { return }
        w.setFrame(rect, display: true)
        v.frame = NSRect(origin: .zero, size: rect.size)
        v.layer?.backgroundColor = (tab ? NSColor.systemPurple : NSColor.controlAccentColor).withAlphaComponent(0.28).cgColor
        v.layer?.borderColor = (tab ? NSColor.systemPurple : NSColor.controlAccentColor).cgColor
        v.layer?.borderWidth = 3; v.layer?.cornerRadius = 8
        w.orderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
}

/// Observes real mouse drags: window drag -> dock/tab on drop; seam drag -> live ratio resize.
/// Uses global+local event monitors (observation only; the user's drag is never swallowed).
@MainActor
final class DragDockMonitor {
    private let tiling: TilingManager
    private let overlay = DockOverlay()
    private var monitors: [Any] = []
    private var dragWindowID: CGWindowID?
    private var dragStart: CGPoint = .zero
    private var seamKey: String?
    private var seamStartX: CGFloat = 0
    private var seamWindowID: CGWindowID?
    /// Window frames captured ONCE at mouse-down. The old code re-enumerated
    /// every window via Accessibility on every mouse-drag event (dozens of
    /// IPC round-trips per second, mid-drag).
    private var cachedFrames: [(id: CGWindowID, rect: CGRect)] = []
    /// True for a gesture that began while Mission Control owns the
    /// screen: coordinates there point at thumbnails, not real windows,
    /// so the whole gesture is ignored.
    private var ignoringGesture = false

    init(tiling: TilingManager) { self.tiling = tiling }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }
    func stop() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors = [] }

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation // cocoa coords
        switch e.type {
        case .leftMouseDown:
            dragStart = p
            ignoringGesture = AXWindowService.isSystemOverviewActive()
            if ignoringGesture { return }
            cachedFrames = tiling.windowCocoaFrames()
            // Seam first: grabbing a divider resizes both neighbours.
            for (key, rect) in tiling.seamRectsCocoa() where rect.contains(p) {
                seamKey = key; seamStartX = p.x
                seamWindowID = cachedFrames.min(by: { abs($0.rect.minX - rect.minX) < abs($1.rect.minX - rect.minX) })?.id
                return
            }
            // Only the FRONTMOST window under the cursor (cachedFrames is
            // z-ordered), grabbed by its title-bar band, starts a drag.
            if let front = cachedFrames.first(where: { $0.rect.contains(p) }),
               DockGeometry.isTitleBarDrag(point: p, in: front.rect) {
                dragWindowID = front.id
            }
        case .leftMouseDragged:
            if ignoringGesture { return }
            if seamKey != nil, let wid = seamWindowID {
                let delta = Double((p.x - seamStartX) / 600.0)
                if abs(p.x - seamStartX) > 4 { tiling.resizeSeam(containing: wid, delta: delta > 0 ? 0.02 : -0.02); seamStartX = p.x }
                return
            }
            guard let dragged = dragWindowID, hypot(p.x - dragStart.x, p.y - dragStart.y) > 10 else { return }
            if let target = cachedFrames.first(where: { $0.id != dragged && $0.rect.contains(p) }) {
                let zone = DockGeometry.zone(at: p, in: target.rect)
                overlay.show(rect: previewRect(zone: zone, in: target.rect), tab: zone == .center)
            } else if let scr = NSScreen.screens.first(where: { $0.visibleFrame.contains(p) }) {
                let zone = DockGeometry.zone(at: p, in: scr.visibleFrame)
                overlay.show(rect: previewRect(zone: zone, in: scr.visibleFrame), tab: false)
            }
        case .leftMouseUp:
            defer { overlay.hide(); dragWindowID = nil; seamKey = nil; seamWindowID = nil; cachedFrames = []; ignoringGesture = false }
            // Gesture began in (or ended in — e.g. hot-corner) Mission
            // Control: never dock based on thumbnail coordinates.
            if ignoringGesture || AXWindowService.isSystemOverviewActive() { return }
            if seamKey != nil { return } // live resize already applied
            guard let dragged = dragWindowID, hypot(p.x - dragStart.x, p.y - dragStart.y) > 10 else { return }
            // Detector-independent proof of a real window drag: the actual
            // window must have moved in the real Space. In Mission Control
            // you drag a thumbnail — the real frame stays put — so this
            // bails out even if every other MC signal missed.
            guard let startFrame = cachedFrames.first(where: { $0.id == dragged })?.rect,
                  let nowFrame = tiling.currentCocoaFrame(of: dragged),
                  AnimationTiming.framesDiffer(startFrame, nowFrame) else { return }
            // A window the user just dragged by hand must not be re-docked onto itself.
            // Drop targets didn't move during the drag, so the cached frames are still right.
            let target = cachedFrames.first(where: { $0.id != dragged && $0.rect.contains(p) })
            let zone: DockZone
            if let t = target { zone = DockGeometry.zone(at: p, in: t.rect) }
            else if let scr = NSScreen.screens.first(where: { $0.visibleFrame.contains(p) }) { zone = DockGeometry.zone(at: p, in: scr.visibleFrame) }
            else { return }
            tiling.dock(draggedID: dragged, targetID: target?.id, zone: zone, atCocoaPoint: p)
        default: break
        }
    }

    private func previewRect(zone: DockZone, in r: CGRect) -> CGRect {
        switch zone {
        case .center: return r
        case .left: return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        case .bottom: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        }
    }
}
