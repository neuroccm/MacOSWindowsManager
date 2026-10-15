import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var tiling: TilingManager
    @State private var newExclusion: String = ""

    var body: some View {
        Form {
            Section("Window management") {
                Toggle("Enable automatic tiling", isOn: $settings.isTilingEnabled)
                    .onChange(of: settings.isTilingEnabled) { _, on in if on { tiling.tileAll() } }
                Picker("Layout", selection: $settings.layoutMode) {
                    ForEach(LayoutMode.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: settings.layoutMode) { _, _ in tiling.tileAll() }
                HStack {
                    Text("Gap: \(Int(settings.gap)) px")
                    Slider(value: $settings.gap, in: 0...32, step: 2)
                        .onChange(of: settings.gap) { _, _ in if settings.isTilingEnabled { tiling.tileAll() } }
                }
                HStack {
                    Text("Master ratio: \(Int(settings.masterRatio * 100))%")
                    Slider(value: $settings.masterRatio, in: 0.3...0.8, step: 0.05)
                        .onChange(of: settings.masterRatio) { _, _ in if settings.isTilingEnabled { tiling.tileAll() } }
                }
                Text(tiling.lastStatus).font(.caption).foregroundStyle(.secondary)
                Text("\(tiling.lastWindowCount) managed window(s) · \(NSScreen.screens.count) display(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zoom, tabs & seams") {
                HStack {
                    Button("Overview (⌃⌥Space)") { tiling.showOverview() }
                    Button("Zoom in (⌃⌥↓)") { tiling.zoomInFocused() }
                    Button("Step out (⌃⌥↑)") { tiling.zoomOut() }
                }
                HStack {
                    Button("Back (⌃⌥[)") { tiling.goBack() }
                    Button("Forward (⌃⌥])") { tiling.goForward() }
                    Button("Next tab (⌃⌥Y)") { tiling.cycleTab(forward: true) }
                    Button("Tear tab off (⌃⌥T)") { tiling.tearOffFocused() }
                }
                HStack {
                    Button("Seam − (⌃⌥-)") { tiling.resizeFocusedSeam(delta: -0.05) }
                    Button("Seam + (⌃⌥=)") { tiling.resizeFocusedSeam(delta: 0.05) }
                }
                Text("Drag a window onto another's center to tab it, onto an edge to dock it, or to a screen edge to dock beside everything. Drag the gap between windows to resize the seam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hotkeys (⌃⌥ = Control + Option)") {
                Text("⌃⌥Space Overview · ⌃⌥F Float all · ⌃⌥↩ Maximize · ⌃⌥↓/↑ Zoom in/out\n⌃⌥[ / ] Back/Forward · ⌃⌥Y Next tab · ⌃⌥T Tear off · ⌃⌥-/= Seam\n⌃⌥Tab Next window · ⌃⌥D Next display · ⌃⌥S/B/M/C/G Layouts\n⌃⌥⇧1 Save view 1 · ⌃⌥1/2/3 Restore view")
                    .font(.caption)
            }
            Section("Excluded apps (never arranged)") {
                ForEach(Array(settings.excludedBundleIDs).sorted(), id: \.self) { bid in
                    HStack { Text(bid).font(.caption); Spacer()
                        Button("Remove") { settings.excludedBundleIDs.remove(bid) } }
                }
                HStack {
                    TextField("com.example.App", text: $newExclusion)
                    Button("Exclude frontmost app") {
                        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                            settings.excludedBundleIDs.insert(bid)
                        }
                    }
                    Button("Add") {
                        let v = newExclusion.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty { settings.excludedBundleIDs.insert(v); newExclusion = "" }
                    }
                }
            }
            Section("Permissions") {
                HStack {
                    Text(AXWindowService.isAccessibilityTrusted(prompt: false) ? "Accessibility: granted" : "Accessibility: needed to move/resize windows")
                    Spacer()
                    Button("Open Settings") { AXWindowService.openAccessibilitySettings() }
                }
                HStack {
                    Text("Screen Recording: optional (live previews only — not used in v1)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { AXWindowService.openScreenRecordingSettings() }
                }
            }
            Section {
                Button("Tile all now") { tiling.tileAll() }
                Button("Float all (restore originals)") { tiling.floatAll() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}

struct OnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacOSWindowsManager needs Accessibility").font(.title2.bold())
            Text("Accessibility is how any app moves and resizes another app's windows on macOS. Nothing leaves this Mac — no account, no network, no pay tier.")
            Text("1. Click Open Accessibility Settings\n2. Enable MacOSWindowsManager\n3. Return here — tiling will start working immediately.")
                .font(.callout)
            HStack {
                Button("Open Accessibility Settings") { _ = AXWindowService.isAccessibilityTrusted(prompt: true); AXWindowService.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Continue to menu bar app") { NSApp.keyWindow?.close() }
            }
            Text("Tip: the app lives in the menu bar (rectangle icon). Quit restores every window to a visible position.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 520)
    }
}
