import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

public final class ManagedWindow {
    public let snapshot: WindowSnapshot
    public let element: AXUIElement
    public let appElement: AXUIElement
    public init(snapshot: WindowSnapshot, element: AXUIElement, appElement: AXUIElement) {
        self.snapshot = snapshot; self.element = element; self.appElement = appElement
    }
}

public enum AXWindowService {
    public static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func copyAttribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }
    private static func stringAttribute(_ el: AXUIElement, _ attr: String) -> String {
        (copyAttribute(el, attr) as? String) ?? ""
    }
    /// Type-checked AXValue extraction (the old force-cast could crash on
    /// apps that return unexpected attribute types).
    private static func axValue(_ raw: CFTypeRef?) -> AXValue? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue) // type ID checked above
    }
    public static func frame(of el: AXUIElement) -> CGRect? {
        guard let posVal = axValue(copyAttribute(el, kAXPositionAttribute)),
              let sizeVal = axValue(copyAttribute(el, kAXSizeAttribute)) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        AXValueGetValue(sizeVal, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
    public static func windowID(of el: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(el, &id)
        return id
    }

    @discardableResult
    public static func setFrame(_ frame: CGRect, on el: AXUIElement) -> Bool {
        setFrame(frame, on: el, from: nil)
    }

    /// Sets only what changed vs `current`: a move-only update is 1 AX call instead of 3.
    /// The second size set (correcting apps that clamp size to the old position) runs
    /// only when the size actually changed.
    @discardableResult
    public static func setFrame(_ frame: CGRect, on el: AXUIElement, from current: CGRect?) -> Bool {
        let sizeChanged = current.map { abs($0.width - frame.width) > 0.5 || abs($0.height - frame.height) > 0.5 } ?? true
        let posChanged = current.map { abs($0.minX - frame.minX) > 0.5 || abs($0.minY - frame.minY) > 0.5 } ?? true
        var size = frame.size
        var pos = frame.origin
        if sizeChanged, let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
        if posChanged, let v = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
        if sizeChanged, let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
        return true
    }

    /// Raise without activating the app — visibility only, no focus steal.
    public static func raise(_ w: ManagedWindow) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    }

    public static func focus(_ w: ManagedWindow) {
        raise(w)
        NSRunningApplication(processIdentifier: w.snapshot.pid)?.activate(options: [.activateAllWindows])
    }

    /// Attributes fetched per window in ONE batched AX call (was 6 separate
    /// IPC round-trips per window per enumeration).
    private static let windowAttributes: [String] = [
        kAXRoleAttribute as String, kAXSubroleAttribute as String,
        kAXMinimizedAttribute as String, kAXPositionAttribute as String,
        kAXSizeAttribute as String, kAXTitleAttribute as String,
    ]

    /// Window IDs actually visible on the current Space, frontmost first.
    /// Only IDs/bounds/owner are read, so no Screen Recording permission
    /// is needed. AX alone happily reports windows on other Spaces and
    /// windows of hidden apps; intersecting with this list is what keeps
    /// Mission Control trips and Space switches from looking like
    /// "windows opened/closed" to the tiling planner.
    public static func onScreenWindowIDsInZOrder() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// True while Mission Control / Exposé / Launchpad owns the screen.
    /// Signal: the Dock (which hosts those UIs) is the frontmost app.
    /// In normal work the Dock is never frontmost, so this cannot wedge
    /// tiling off. The previous signal — a full-display Dock-level CG
    /// window — matched a permanent Dock canvas window on current macOS
    /// and disabled tiling entirely (build-4 regression, live-probed).
    public static func isSystemOverviewActive() -> Bool {
        isOverviewFrontmostApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Pure frontmost-app test behind the overview detector (unit-tested).
    static func isOverviewFrontmostApp(_ bundleID: String?) -> Bool {
        bundleID == "com.apple.dock"
    }

    public static func allWindows(excludedBundleIDs: Set<String>, onScreenOnly: Bool = true) -> [ManagedWindow] {
        guard isAccessibilityTrusted(prompt: false) else { return [] }
        // Fail OPEN: an empty on-screen list means the CG query failed or
        // is restricted — never let it veto every real window.
        let onScreenIDs = onScreenWindowIDsInZOrder()
        let onScreen: Set<CGWindowID>? = (onScreenOnly && !onScreenIDs.isEmpty) ? Set(onScreenIDs) : nil
        var out: [ManagedWindow] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let attrs = windowAttributes as CFArray
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != ownPID else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            if excludedBundleIDs.contains(bundleID) { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success,
                  let elements = raw as? [AXUIElement] else { continue }
            for el in elements {
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                      let vs = values as? [Any?], vs.count == windowAttributes.count else {
                    // Fall back to per-attribute reads for nonconformant apps.
                    if let w = slowWindow(el, appEl: appEl, app: app, bundleID: bundleID),
                       onScreen.map({ $0.contains(w.snapshot.windowID) }) ?? true { out.append(w) }
                    continue
                }
                let role = vs[0] as? String ?? ""
                if role != (kAXWindowRole as String) { continue }
                let sub = vs[1] as? String ?? ""
                if !sub.isEmpty && sub != (kAXStandardWindowSubrole as String) { continue }
                if (vs[2] as? Bool) ?? false { continue } // minimized
                guard let posVal = axValue(vs[3] as CFTypeRef?), let sizeVal = axValue(vs[4] as CFTypeRef?) else { continue }
                var pos = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(posVal, .cgPoint, &pos)
                AXValueGetValue(sizeVal, .cgSize, &size)
                guard size.width > 80, size.height > 80 else { continue }
                let wid = windowID(of: el)
                if wid == 0 { continue }
                if let onScreen, !onScreen.contains(wid) { continue } // other Space / hidden app
                out.append(ManagedWindow(
                    snapshot: WindowSnapshot(windowID: wid, pid: app.processIdentifier,
                        appName: app.localizedName ?? bundleID, bundleID: bundleID,
                        title: vs[5] as? String ?? "", axFrame: CGRect(origin: pos, size: size)),
                    element: el, appElement: appEl))
            }
        }
        return out
    }

    private static func slowWindow(_ el: AXUIElement, appEl: AXUIElement, app: NSRunningApplication, bundleID: String) -> ManagedWindow? {
        if stringAttribute(el, kAXRoleAttribute) != (kAXWindowRole as String) { return nil }
        let sub = stringAttribute(el, kAXSubroleAttribute)
        if !sub.isEmpty && sub != (kAXStandardWindowSubrole as String) { return nil }
        if (copyAttribute(el, kAXMinimizedAttribute) as? Bool) ?? false { return nil }
        guard let f = frame(of: el), f.width > 80, f.height > 80 else { return nil }
        let wid = windowID(of: el)
        if wid == 0 { return nil }
        return ManagedWindow(
            snapshot: WindowSnapshot(windowID: wid, pid: app.processIdentifier,
                appName: app.localizedName ?? bundleID, bundleID: bundleID,
                title: stringAttribute(el, kAXTitleAttribute), axFrame: f),
            element: el, appElement: appEl)
    }

    /// Cheap focused-window lookup: asks only the frontmost app (1-2 AX
    /// calls) instead of enumerating every window of every app.
    public static func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let id = windowID(of: raw as! AXUIElement) // type ID checked above
        return id == 0 ? nil : id
    }

    public static func focusedWindow(excludedBundleIDs: Set<String>) -> ManagedWindow? {
        guard let fid = focusedWindowID() else { return nil }
        return allWindows(excludedBundleIDs: excludedBundleIDs).first { $0.snapshot.windowID == fid }
    }
}
