import SwiftUI

@main
struct MacOSWindowsManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.settings, tiling: appDelegate.tiling)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
