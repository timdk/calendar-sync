import CryptoKit
import EventKit
import Foundation

// Stateless sync, same approach as the original CLI: each run works out which
// blockers should exist in the window, creates the missing ones and deletes
// the stale ones. Blockers carry only an opaque marker in their notes:
//
//   [calsync] <8-hex hash of source calendar id>:<16-hex hash of event id + times>
//
// so nothing about the original meeting crosses between calendars.

let blockerMarker = "[calsync]"

struct PairReport: Identifiable {
    var id: DirectedPair { pair }
    let pair: DirectedPair
    var blockers = 0
    var error: String?
}

struct SyncReport {
    var date = Date()
    var dryRun = false
    var created = 0
    var removed = 0
    var pairs: [PairReport] = []
    var changes: [String] = []
    var errors: [String] = []

    var summary: String {
        "\(dryRun ? "Preview: would create" : "Created") \(created), \(dryRun ? "remove" : "removed") \(removed)"
            + (errors.isEmpty ? "" : ", \(errors.count) error(s)")
    }
}

@MainActor
struct SyncEngine {
    let store: EKEventStore
    let config: SyncConfig

    static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func tag(forCalendar id: String) -> String { String(sha(id).prefix(8)) }

    /// Extracts (source tag, event key) from a blocker's notes. Searches rather than
    /// matching a prefix in case the server wraps notes in HTML or adds text.
    static func parseMarker(_ e: EKEvent) -> (tag: String, key: String)? {
        guard let notes = e.notes, notes.contains(blockerMarker) else { return nil }
        let regex = try! Regex(#"\[calsync\] ([0-9a-f]{8}):([0-9a-f]{16})"#)
        guard let m = notes.firstMatch(of: regex),
              let tag = m[1].substring, let key = m[2].substring else { return nil }
        return (String(tag), String(key))
    }

    static func label(_ cal: EKCalendar) -> String { "\(cal.title) (\(cal.source.title))" }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func describe(_ e: EKEvent) -> String {
        "\(timeFormat.string(from: e.startDate))–\(DateFormatter.localizedString(from: e.endDate, dateStyle: .none, timeStyle: .short))"
    }

    private func events(in cal: EKCalendar, from start: Date, to end: Date) -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [cal]))
    }

    /// Skip our own blockers (prevents ping-pong), all-day events, free/cancelled
    /// events, meetings you've declined and, optionally, tentative ones.
    private func shouldMirror(_ e: EKEvent) -> Bool {
        if Self.parseMarker(e) != nil || e.isAllDay || e.availability == .free || e.status == .canceled { return false }
        if !config.mirrorTentative && (e.availability == .tentative || e.status == .tentative) { return false }
        if e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { return false }
        return true
    }

    func run(dryRun: Bool) -> SyncReport {
        var r = SyncReport(dryRun: dryRun)
        store.refreshSourcesIfNecessary()

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: config.daysAhead, to: start)!
        let pairs = config.directedPairs
        var dirty = false

        func remove(_ b: EKEvent, from cal: EKCalendar, why: String) {
            r.changes.append("\(dryRun ? "Would remove" : "Removed") \(why) blocker \(Self.describe(b)) from \(Self.label(cal))")
            r.removed += 1
            guard !dryRun else { return }
            do { try store.remove(b, span: .thisEvent, commit: false); dirty = true }
            catch { r.errors.append("Remove from \(Self.label(cal)) failed: \(error.localizedDescription)") }
        }

        for p in pairs {
            var rep = PairReport(pair: p)
            defer { r.pairs.append(rep) }
            guard let from = store.calendar(withIdentifier: p.from) else { rep.error = "Source calendar not found"; continue }
            guard let to = store.calendar(withIdentifier: p.to) else { rep.error = "Target calendar not found"; continue }
            guard to.allowsContentModifications else { rep.error = "\(Self.label(to)) is read-only"; continue }
            let tag = Self.tag(forCalendar: from.calendarIdentifier)

            // Blockers that should exist, keyed by a hash of source event + times.
            // A moved event gets a new key -> old blocker removed, new one created.
            var wanted: [String: EKEvent] = [:]
            for e in events(in: from, from: start, to: end) where shouldMirror(e) {
                let id = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? ""
                let k = String(Self.sha("\(tag)|\(id)|\(e.startDate.timeIntervalSince1970)|\(e.endDate.timeIntervalSince1970)").prefix(16))
                wanted[k] = e
            }

            // Remove stale or duplicate blockers; remember the ones to keep.
            var have = Set<String>()
            for b in events(in: to, from: start, to: end) {
                guard let m = Self.parseMarker(b), m.tag == tag else { continue }
                if wanted[m.key] != nil && have.insert(m.key).inserted { continue }
                remove(b, from: to, why: "stale")
            }

            // Create missing blockers.
            for (k, e) in wanted.sorted(by: { $0.value.startDate < $1.value.startDate }) where !have.contains(k) {
                r.changes.append("\(dryRun ? "Would create" : "Created") blocker \(Self.describe(e)) in \(Self.label(to))")
                r.created += 1
                guard !dryRun else { continue }
                let b = EKEvent(eventStore: store)
                b.calendar = to
                b.title = config.blockerTitle
                b.startDate = e.startDate
                b.endDate = e.endDate
                b.availability = .busy
                b.notes = "\(blockerMarker) \(tag):\(k)"
                do { try store.save(b, span: .thisEvent, commit: false); dirty = true }
                catch { r.errors.append("Create in \(Self.label(to)) failed: \(error.localizedDescription)") }
            }
            rep.blockers = wanted.count
        }

        // Orphans: blockers whose link was deleted or changed. Pairs whose calendars
        // are temporarily missing still count as active, so their blockers survive.
        var activeTags: [String: Set<String>] = [:]
        for p in pairs { activeTags[p.to, default: []].insert(Self.tag(forCalendar: p.from)) }
        for cal in store.calendars(for: .event) where cal.allowsContentModifications {
            let valid = activeTags[cal.calendarIdentifier] ?? []
            for b in events(in: cal, from: start, to: end) {
                guard let m = Self.parseMarker(b), !valid.contains(m.tag) else { continue }
                remove(b, from: cal, why: "orphaned")
            }
        }

        if dirty {
            do { try store.commit() }
            catch {
                store.reset()
                r.errors.append("Saving changes failed: \(error.localizedDescription)")
            }
        }
        return r
    }

    /// Deletes every CalSync blocker from now until a year out, in every writable calendar.
    func removeAllBlockers() -> SyncReport {
        var r = SyncReport()
        let start = Date()
        let end = Calendar.current.date(byAdding: .year, value: 1, to: start)!
        for cal in store.calendars(for: .event) where cal.allowsContentModifications {
            // predicateForEvents spans at most 4 years, so one query is fine.
            for b in events(in: cal, from: start, to: end) where Self.parseMarker(b) != nil {
                do { try store.remove(b, span: .thisEvent, commit: false); r.removed += 1 }
                catch { r.errors.append("Remove from \(Self.label(cal)) failed: \(error.localizedDescription)") }
            }
        }
        if r.removed > 0 {
            do { try store.commit() }
            catch { store.reset(); r.errors.append("Saving changes failed: \(error.localizedDescription)") }
        }
        return r
    }
}
