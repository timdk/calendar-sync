import SwiftUI

@main
struct CalSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("CalSync Settings", id: "settings") {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    private var menuIcon: String {
        if !model.hasAccess || model.lastError != nil { return "calendar.badge.exclamationmark" }
        if model.config.paused { return "calendar.badge.minus" }
        return "calendar.badge.clock"
    }
}
