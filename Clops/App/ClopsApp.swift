import SwiftUI

@main
struct ClopsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: appDelegate.preferences,
                store: appDelegate.store,
                monitor: appDelegate.monitor,
                coordinator: appDelegate.coordinator,
                hotKey: appDelegate.hotKey
            )
        }
    }
}
