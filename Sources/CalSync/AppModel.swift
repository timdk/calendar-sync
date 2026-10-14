import AppKit
import EventKit
import Foundation
import Observation
import ServiceManagement

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let isError: Bool
}

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let store = EKEventStore()

    var config = SyncConfig.load() {
        didSet { configChanged(from: oldValue) }
    }
    var access = EKEventStore.authorizationStatus(for: .event)
    var calendars: [EKCalendar] = []
    var lastReport: SyncReport?
    var lastError: String?
    var preview: SyncReport?
    var nextSync: Date?
    var log: [LogEntry] = []
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CalSync.log")

    var hasAccess: Bool { access == .fullAccess }

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give calendar accounts a moment to catch up after waking.
            MainActor.assumeIsolated { self?.syncSoon(after: 30) }
        })
        Task { await requestAccess() }
    }

    // MARK: Access

    func requestAccess() async {
        if access == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            append("No full calendar access. Allow it in System Settings → Privacy & Security → Calendars.", isError: true)
            return
        }
        reloadCalendars()
        sync()
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    // MARK: Calendars

    func reloadCalendars() {
        calendars = store.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
    }

    func calendar(_ id: String) -> EKCalendar? {
        calendars.first { $0.calendarIdentifier == id }
    }

    func calendarName(_ id: String) -> String {
        calendar(id).map(SyncEngine.label) ?? "Missing calendar"
    }

    /// Returns a problem with a link that will stop it syncing, if any.
    func problem(with link: SyncLink) -> String? {
        if link.sourceID.isEmpty || link.targetID.isEmpty { return "Choose both calendars." }
        if link.sourceID == link.targetID { return "Source and target are the same calendar." }
        guard let s = calendar(link.sourceID), let t = calendar(link.targetID) else { return "A calendar is missing." }
        if !t.allowsContentModifications { return "\(t.title) is read-only, so blockers can't be written to it." }
        if link.bidirectional && !s.allowsContentModifications { return "\(s.title) is read-only; make this link one-way." }
        return nil
    }

    // MARK: Sync

    func sync() {
        pending?.cancel()
        guard hasAccess, !config.paused else { reschedule(); return }
        let report = SyncEngine(store: store, config: config).run(dryRun: false)
        lastReport = report
        lastError = report.errors.last ?? report.pairs.compactMap(\.error).first
        for c in report.changes { append(c) }
        for e in report.errors { append(e, isError: true) }
        if report.created + report.removed > 0 || !report.errors.isEmpty { append(report.summary) }
        reschedule()
    }

    func runPreview() {
        guard hasAccess else { return }
        preview = SyncEngine(store: store, config: config).run(dryRun: true)
    }

    /// Pauses syncing (otherwise the blockers come straight back) and deletes them all.
    func removeAllBlockers() {
        guard hasAccess else { return }
        config.paused = true
        let r = SyncEngine(store: store, config: config).removeAllBlockers()
        for e in r.errors { append(e, isError: true) }
        append("Removed all \(r.removed) blocker(s); syncing paused.")
        preview = nil
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        nextSync = nil
        guard hasAccess, !config.paused else { return }
        let interval = TimeInterval(max(1, config.intervalMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        nextSync = Date().addingTimeInterval(interval)
    }

    private func syncSoon(after seconds: Double) {
        guard hasAccess, !config.paused else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// Calendar data changed (an account synced, or we wrote blockers). Debounce
    /// and resync; a resync after our own writes finds nothing to do and stops.
    private func storeChanged() {
        reloadCalendars()
        syncSoon(after: 10)
    }

    private func configChanged(from old: SyncConfig) {
        config.save()
        preview = nil
        if old.paused != config.paused {
            append(config.paused ? "Syncing paused." : "Syncing resumed.")
            if config.paused { pending?.cancel(); reschedule() } else { sync() }
        } else if old.intervalMinutes != config.intervalMinutes {
            reschedule()
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            append("Launch at login: \(error.localizedDescription)", isError: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Log

    func append(_ text: String, isError: Bool = false) {
        let entry = LogEntry(date: Date(), text: text, isError: isError)
        log.append(entry)
        if log.count > 300 { log.removeFirst(log.count - 300) }

        let line = "\(ISO8601DateFormatter().string(from: entry.date)) \(isError ? "ERROR " : "")\(text)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: Self.logURL)
        }
    }
}
