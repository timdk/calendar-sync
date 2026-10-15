import CryptoKit
import EventKit
import Foundation

// Stateless sync, same approach as the original CLI: each run works out which
// blockers should exist in the window, creates the missing ones and deletes
// the stale ones. Blockers carry only an opaque marker in their notes:
//
//   [calsync] <8-hex hash of source calendar id>:<16-hex hash of event id + times>
//
// so nothing about the original meeting crosses between calendars, unless the
// link has "copy details" on: then the blocker also gets the meeting title
// (optionally prefixed with the source calendar's name) and its join link.

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

    /// The calendar's alias, else its account name (calendar titles like "Calendar" say nothing).
    static func shortName(_ cal: EKCalendar, config: SyncConfig) -> String {
        config.alias(for: cal.calendarIdentifier) ?? cal.source.title
    }

    /// Alias-aware label for logs and the UI.
    static func label(_ cal: EKCalendar, config: SyncConfig) -> String {
        config.alias(for: cal.calendarIdentifier).map { "\($0) (\(cal.source.title))" } ?? label(cal)
    }

    /// Hosts whose links count as a meeting's join link.
    static let meetingHosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com",
                               "webex.com", "gotomeeting.com", "goto.com", "whereby.com", "chime.aws"]
    private static let urlRegex = try! Regex(#"https?://[^\s<>"'\]\)]+"#)

    /// Finds the join link in the event's URL, location or notes. Exchange usually
    /// leaves `url` empty and puts the Teams link in the invite body.
    static func meetingLink(in e: EKEvent) -> URL? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            for m in text.matches(of: urlRegex) {
                var raw = String(text[m.range]).replacingOccurrences(of: "&amp;", with: "&")
                while let last = raw.last, ".,;:".contains(last) { raw.removeLast() }
                guard var url = URL(string: raw) else { continue }
                // Unwrap Outlook Safe Links so the copy doesn't depend on the other org's scanner.
                if url.host?.hasSuffix("safelinks.protection.outlook.com") == true,
                   let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                       .queryItems?.first(where: { $0.name == "url" })?.value,
                   let innerURL = URL(string: inner) {
                    url = innerURL
                }
                guard let host = url.host?.lowercased(),
                      meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                return url
            }
        }
        return nil
    }

    /// What the blocker for `e` should contain under pair `p`.
    private func content(for e: EKEvent, pair p: DirectedPair, source: EKCalendar) -> (title: String, link: URL?) {
        guard p.copyDetails else { return (config.blockerTitle, nil) }
        var title = e.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = config.blockerTitle }
        if p.prefixTitles { title = "[\(Self.shortName(source, config: config))] \(title)" }
        return (title, Self.meetingLink(in: e))
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func describe(_ e: EKEvent) -> String {
        "\(timeFormat.string(from: e.startDate))–\(DateFormatter.localizedString(from: e.endDate, dateStyle: .none, timeStyle: .short))"
    }

    private func name(_ cal: EKCalendar) -> String { Self.label(cal, config: config) }

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
            r.changes.append("\(dryRun ? "Would remove" : "Removed") \(why) “\(b.title ?? "")” \(Self.describe(b)) from \(name(cal))")
            r.removed += 1
            guard !dryRun else { return }
            do { try store.remove(b, span: .thisEvent, commit: false); dirty = true }
            catch { r.errors.append("Remove from \(name(cal)) failed: \(error.localizedDescription)") }
        }

        for p in pairs {
            var rep = PairReport(pair: p)
            defer { r.pairs.append(rep) }
            guard let from = store.calendar(withIdentifier: p.from) else { rep.error = "Source calendar not found"; continue }
            guard let to = store.calendar(withIdentifier: p.to) else { rep.error = "Target calendar not found"; continue }
            guard to.allowsContentModifications else { rep.error = "\(name(to)) is read-only"; continue }
            let tag = Self.tag(forCalendar: from.calendarIdentifier)

            // Blockers that should exist, keyed by a hash of source event + times
            // (+ title and link when copying details). A moved or renamed event gets
            // a new key -> old blocker removed, new one created.
            var wanted: [String: (event: EKEvent, title: String, link: URL?)] = [:]
            for e in events(in: from, from: start, to: end) where shouldMirror(e) {
                let id = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? ""
                let c = content(for: e, pair: p, source: from)
                var keySource = "\(tag)|\(id)|\(e.startDate.timeIntervalSince1970)|\(e.endDate.timeIntervalSince1970)"
                if p.copyDetails { keySource += "|\(c.title)|\(c.link?.absoluteString ?? "")" }
                wanted[String(Self.sha(keySource).prefix(16))] = (e, c.title, c.link)
            }

            // Remove stale or duplicate blockers; remember the ones to keep.
            var have = Set<String>()
            for b in events(in: to, from: start, to: end) {
                guard let m = Self.parseMarker(b), m.tag == tag else { continue }
                if wanted[m.key] != nil && have.insert(m.key).inserted { continue }
                remove(b, from: to, why: "stale")
            }

            // Create missing blockers.
            for (k, w) in wanted.sorted(by: { $0.value.event.startDate < $1.value.event.startDate }) where !have.contains(k) {
                let e = w.event
                r.changes.append("\(dryRun ? "Would create" : "Created") “\(w.title)” \(Self.describe(e)) in \(name(to))")
                r.created += 1
                guard !dryRun else { continue }
                let b = EKEvent(eventStore: store)
                b.calendar = to
                b.title = w.title
                b.url = w.link
                b.startDate = e.startDate
                b.endDate = e.endDate
                b.availability = .busy
                b.notes = (w.link.map { "Join: \($0.absoluteString)\n\n" } ?? "") + "\(blockerMarker) \(tag):\(k)"
                do { try store.save(b, span: .thisEvent, commit: false); dirty = true }
                catch { r.errors.append("Create in \(name(to)) failed: \(error.localizedDescription)") }
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
                catch { r.errors.append("Remove from \(name(cal)) failed: \(error.localizedDescription)") }
            }
        }
        if r.removed > 0 {
            do { try store.commit() }
            catch { store.reset(); r.errors.append("Saving changes failed: \(error.localizedDescription)") }
        }
        return r
    }
}
