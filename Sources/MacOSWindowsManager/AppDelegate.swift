import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    lazy var tiling = TilingManager(settings: settings)
    let hotkeys = HotkeyManager()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var aboutWindow: NSWindow?
    private lazy var dragMonitor = DragDockMonitor(tiling: tiling)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupHotkeys()
        observeWorkspace()
        if !AXWindowService.isAccessibilityTrusted(prompt: false) { showOnboarding() }
        dragMonitor.start()
        if settings.isTilingEnabled { tiling.tileAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit, and every window goes back to a visible position.
        tiling.restoreOnQuit()
        hotkeys.unregisterAll()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "MacOSWindowsManager")
        item.button?.title = ""
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        menu.addItem(NSMenuItem(title: "About MacOSWindowsManager  (v\(version), build \(build))", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        let trusted = AXWindowService.isAccessibilityTrusted(prompt: false)
        menu.addItem(NSMenuItem(title: trusted ? "Accessibility: granted" : "Accessibility: NEEDED — click Settings", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: tiling.lastStatus, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: settings.isTilingEnabled ? "Disable automatic tiling" : "Enable automatic tiling", action: #selector(toggleTiling), keyEquivalent: "")
        menu.addItem(toggle)
        menu.addItem(NSMenuItem(title: "Tile all windows now  (⌃⌥Space)", action: #selector(tileNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Float all — restore originals  (⌃⌥F)", action: #selector(floatAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Maximize focused  (⌃⌥↩)", action: #selector(maximize), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Move focused to next display  (⌃⌥D)", action: #selector(nextDisplay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Overview — see everything  (⌃⌥Space)", action: #selector(overview), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Zoom into focused  (⌃⌥↓)", action: #selector(zoomIn), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Step out / zoom out  (⌃⌥↑)", action: #selector(zoomOut), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Back  (⌃⌥[)", action: #selector(goBack), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forward  (⌃⌥])", action: #selector(goForward), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Next tab in group  (⌃⌥Y)", action: #selector(tabNext), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Tear tab off  (⌃⌥T)", action: #selector(tearOff), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Grow seam  (⌃⌥=) / Shrink  (⌃⌥-)", action: #selector(seamGrow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Drag windows to dock/tab · drag seams to resize", action: nil, keyEquivalent: ""))

        let layoutMenu = NSMenu()
        for mode in LayoutMode.allCases {
            let mi = NSMenuItem(title: mode.displayName, action: #selector(selectLayout(_:)), keyEquivalent: "")
            mi.representedObject = mode.rawValue
            mi.state = settings.layoutMode == mode ? .on : .off
            layoutMenu.addItem(mi)
        }
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        let viewsMenu = NSMenu()
        for slot in 1...3 {
            let s = NSMenuItem(title: "Save view \(slot)", action: #selector(saveView(_:)), keyEquivalent: "")
            s.tag = slot; viewsMenu.addItem(s)
            let r = NSMenuItem(title: "Restore view \(slot)", action: #selector(restoreView(_:)), keyEquivalent: "")
            r.tag = slot; viewsMenu.addItem(r)
        }
        let viewsItem = NSMenuItem(title: "Saved views (per arrangement)", action: nil, keyEquivalent: "")
        viewsItem.submenu = viewsMenu
        menu.addItem(viewsItem)

        menu.addItem(NSMenuItem(title: "Displays: \(NSScreen.screens.count) — each keeps its own layout", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit & restore windows", action: #selector(quitApp), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem?.menu = menu
    }

    private func setupHotkeys() {
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .tileAll: self.settings.isTilingEnabled = true; self.tiling.showOverview()
            case .floatAll: self.tiling.floatAll()
            case .maximize: self.tiling.maximizeFocused()
            case .focusNext: self.tiling.cycleFocus(forward: true)
            case .focusPrev: self.tiling.cycleFocus(forward: false)
            case .nextDisplay: self.tiling.moveFocusedToNextDisplay()
            case .layoutStable: self.settings.layoutMode = .stable; self.tiling.tileAll()
            case .layoutBSP: self.settings.layoutMode = .bsp; self.tiling.tileAll()
            case .layoutMaster: self.settings.layoutMode = .masterStack; self.tiling.tileAll()
            case .layoutColumns: self.settings.layoutMode = .columns; self.tiling.tileAll()
            case .layoutGrid: self.settings.layoutMode = .grid; self.tiling.tileAll()
            case .saveView1: self.tiling.saveView(slot: 1)
            case .restoreView1: self.tiling.restoreView(slot: 1)
            case .zoomIn: self.tiling.zoomInFocused()
            case .zoomOut: self.tiling.zoomOut()
            case .back: self.tiling.goBack()
            case .forward: self.tiling.goForward()
            case .tabNext: self.tiling.cycleTab(forward: true)
            case .tearOff: self.tiling.tearOffFocused()
            case .seamGrow: self.tiling.resizeFocusedSeam(delta: 0.05)
            case .seamShrink: self.tiling.resizeFocusedSeam(delta: -0.05)
            case .restoreView2: self.tiling.restoreView(slot: 2)
            case .restoreView3: self.tiling.restoreView(slot: 3)
            }
            self.rebuildMenu()
        }
        hotkeys.registerAll()
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tiling.scheduleRetile(); self?.rebuildMenu() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tiling.scheduleRetile(); self?.rebuildMenu() }
        }
        // Switching desktops (or returning from Mission Control onto one)
        // must rearrange nothing: adopt the newly visible windows as the
        // baseline after the Space transition settles.
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.tiling.adoptCurrentSpaceAsBaseline(); self?.rebuildMenu()
            }
        }
    }

    private func showOnboarding() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome"
        w.contentView = NSHostingView(rootView: OnboardingView())
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = w
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXWindowService.isAccessibilityTrusted(prompt: false) {
                    self.trustTimer?.invalidate(); self.onboardingWindow?.close(); self.rebuildMenu()
                    if self.settings.isTilingEnabled { self.tiling.tileAll() }
                }
            }
        }
    }

    func showSettingsWindow() { showSettings() }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About MacOSWindowsManager"
            w.contentView = NSHostingView(rootView: AboutView())
            w.center(); aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "MacOSWindowsManager Settings"
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, tiling: tiling))
            w.center(); settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleTiling() { settings.isTilingEnabled.toggle(); if settings.isTilingEnabled { tiling.tileAll() }; rebuildMenu() }
    @objc private func tileNow() { settings.isTilingEnabled = true; tiling.tileAll(); rebuildMenu() }
    @objc private func floatAll() { tiling.floatAll(); rebuildMenu() }
    @objc private func maximize() { tiling.maximizeFocused() }
    @objc private func nextDisplay() { tiling.moveFocusedToNextDisplay() }
    @objc private func selectLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = LayoutMode(rawValue: raw) { settings.layoutMode = mode; tiling.tileAll(); rebuildMenu() }
    }
    @objc private func saveView(_ sender: NSMenuItem) { tiling.saveView(slot: sender.tag); rebuildMenu() }
    @objc private func restoreView(_ sender: NSMenuItem) { tiling.restoreView(slot: sender.tag); rebuildMenu() }
    @objc private func overview() { tiling.showOverview(); rebuildMenu() }
    @objc private func zoomIn() { tiling.zoomInFocused(); rebuildMenu() }
    @objc private func zoomOut() { tiling.zoomOut(); rebuildMenu() }
    @objc private func goBack() { tiling.goBack(); rebuildMenu() }
    @objc private func goForward() { tiling.goForward(); rebuildMenu() }
    @objc private func tabNext() { tiling.cycleTab(forward: true); rebuildMenu() }
    @objc private func tearOff() { tiling.tearOffFocused(); rebuildMenu() }
    @objc private func seamGrow() { tiling.resizeFocusedSeam(delta: 0.05); rebuildMenu() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
