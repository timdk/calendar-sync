import SwiftUI

@main
struct CalSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(nsImage: Self.menuBarImage(menuIcon))
        }
        .menuBarExtraStyle(.window)

        Window("CalSync Settings", id: "settings") {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    /// MenuBarExtra ignores font modifiers on SF Symbols and clips anything taller
    /// than the bar, so draw the symbol scaled to fit a fixed height. Template so it
    /// follows the menu bar's light/dark appearance.
    private static func menuBarImage(_ name: String, height: CGFloat = 18) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "CalSync")?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular)) else { return NSImage() }
        let scale = height / symbol.size.height
        let size = NSSize(width: (symbol.size.width * scale).rounded(.up), height: height)
        let img = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "CalSync"
        return img
    }

    private var menuIcon: String {
        if !model.hasAccess || model.lastError != nil { return "calendar.badge.exclamationmark" }
        if model.config.paused { return "calendar.badge.minus" }
        return "calendar.badge.clock"
    }
}
