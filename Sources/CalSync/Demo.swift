import AppKit
import EventKit
import SwiftUI

// README screenshots with made-up calendars:
//
//   ./build.sh screenshots
//
// launches the app with --demo-screenshots <dir>, which renders the settings window and the menu bar popover to PNGs in that folder,
// then quits. Nothing is read from or written to real calendars or settings.

/// Gives a fake calendar an account name; real EKSources come only from the store.
private final class DemoSource: EKSource {
    private let name: String
    init(_ name: String) { self.name = name; super.init() }
    override var title: String { name }
}

extension AppModel {
    func loadDemoData() {
        func cal(_ title: String, _ account: String, _ color: NSColor) -> EKCalendar {
            // In-memory only; never saved to the store.
            let c = EKCalendar(for: .event, eventStore: store)
            c.title = title
            c.color = color
            c.source = DemoSource(account)
            return c
        }
        let contoso = cal("Calendar", "you@contoso.com", .systemBlue)
        let fabrikam = cal("Calendar", "you@fabrikam.com", .systemOrange)
        let personal = cal("Personal", "iCloud", .systemGreen)
        let family = cal("Family", "iCloud", .systemPurple)
        calendars = [personal, family, contoso, fabrikam].sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }

        var c = SyncConfig()
        c.aliases = [contoso.calendarIdentifier: "Contoso", fabrikam.calendarIdentifier: "Fabrikam"]
        c.links = [
            SyncLink(sourceID: fabrikam.calendarIdentifier, targetID: contoso.calendarIdentifier,
                     bidirectional: true, detailsToTarget: true),
            SyncLink(sourceID: personal.calendarIdentifier, targetID: contoso.calendarIdentifier,
                     bidirectional: false),
        ]
        config = c
        access = .fullAccess

        let now = Date()
        var report = SyncReport(date: now.addingTimeInterval(-90))
        let counts = [12, 9, 3]
        report.pairs = zip(c.directedPairs, counts).map { PairReport(pair: $0, blockers: $1) }
        lastReport = report
        nextSync = now.addingTimeInterval(210)

        let entries = [
            (-1800, "Created “[Fabrikam] Sprint review” 16 Oct 2026, 14:00–15:00 in Contoso (you@contoso.com)"),
            (-1795, "Created 1, removed 0"),
            (-600, "Created “Busy” 17 Oct 2026, 09:30–10:00 in Fabrikam (you@fabrikam.com)"),
            (-420, "Removed stale “[Fabrikam] Design sync” 20 Oct 2026, 11:00–11:30 from Contoso (you@contoso.com)"),
            (-415, "Created “[Fabrikam] Design sync” 20 Oct 2026, 13:00–13:30 in Contoso (you@contoso.com)"),
            (-410, "Created 1, removed 1"),
        ]
        log = entries.map { LogEntry(date: now.addingTimeInterval(TimeInterval($0.0)), text: $0.1, isError: false) }
    }
}

/// Borderless windows can't become key by default.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum Demo {
    static let outputDirectory: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-screenshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()

    static func captureScreenshots(to dir: URL) {
        let model = AppModel(demo: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Taller than usual so the Links tab fits without scrolling.
        let settings = window(SettingsView(height: 672).environment(model), title: "CalSync Settings", titled: true)
        let menu = window(
            MenuView().environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12)),
            title: "", titled: false)

        // Capture each window while it's key, so controls show the accent colour.
        NSApp.activate(ignoringOtherApps: true)
        var queue = [(menu, "menu.png"), (settings, "settings.png")]
        func next() {
            guard !queue.isEmpty else { NSApp.terminate(nil); return }
            let (w, name) = queue.removeFirst()
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(nil)  // no focus ring in the shot
            // Let SwiftUI lay out and redraw as key before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    save(w, to: dir.appendingPathComponent(name))
                    next()
                }
            }
        }
        next()
    }

    private static func window(_ view: some View, title: String, titled: Bool) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let w = KeyableWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: titled ? [.titled, .closable, .miniaturizable] : [.borderless],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = host
        w.isOpaque = titled
        w.backgroundColor = titled ? .windowBackgroundColor : .clear
        w.isReleasedWhenClosed = false
        w.center()
        w.orderFrontRegardless()
        return w
    }

    /// Renders the window's frame view (title bar included) at 2× without needing
    /// screen recording permission.
    private static func save(_ w: NSWindow, to url: URL, scale: CGFloat = 2) {
        guard let view = w.contentView?.superview ?? w.contentView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    }
}
