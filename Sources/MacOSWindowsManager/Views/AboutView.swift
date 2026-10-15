import AppKit
import SwiftUI

/// Explainer shown from the menu bar's About item.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacOSWindowsManager").font(.title2.bold())
                        Text(version).font(.callout).foregroundStyle(.secondary)
                        Text("Your own native window manager for Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                Text("What it does")
                    .font(.headline)
                Text("MacOSWindowsManager arranges your real windows into calm, readable layouts — one independent layout per display. The default Stable layout only ever uses halves and quarters (never slivers), pairs similar apps side by side (two browsers together, a new chat window in a quarter), tabs extra windows behind tiles instead of subdividing further, and leaves everything exactly where it is when you merely click between windows. Manual BSP docking, tabs, seams, and zoom are still there when you want them. It lives quietly in your menu bar, works across one, two, three or more monitors (portrait ones included), and runs entirely on this Mac: no account, no pay tier, no network.")
                    .fixedSize(horizontal: false, vertical: true)

                Text("The five moves")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Dock: drag a window to a screen edge, or onto another window's edge.", systemImage: "rectangle.split.2x1")
                    Label("Tab: drop a window onto another's center; ⌃⌥Y cycles tabs, ⌃⌥T tears one off.", systemImage: "rectangle.stack")
                    Label("Resize: drag the seam between two windows, or use ⌃⌥- / ⌃⌥=.", systemImage: "arrow.left.and.right")
                    Label("Zoom: ⌃⌥Space shows everything, ⌃⌥↓ zooms in, ⌃⌥↑ steps out.", systemImage: "magnifyingglass")
                    Label("Navigate: ⌃⌥[ and ⌃⌥] move back and forward; ⌃⌥⇧1 saves a view, ⌃⌥1 restores it.", systemImage: "clock.arrow.circlepath")
                }
                .font(.callout)

                Text("Good to know")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Text("• Float All (⌃⌥F) and quitting both restore every window to its original position — nothing gets lost.")
                    Text("• Any app can be left alone from Settings → Excluded apps.")
                    Text("• Accessibility permission is how macOS lets one app move another app's windows; Screen Recording is optional and unused in this version.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                Text("Native Swift (AppKit + Accessibility). Inspired by the dock-nest-zoom idea, built clean-room for personal use.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .frame(width: 540, height: 600)
    }
}
