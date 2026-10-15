import Foundation

/// A link between two calendars. Busy time in `sourceID` is mirrored into
/// `targetID` (and the other way round when `bidirectional`).
struct SyncLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceID = ""
    var targetID = ""
    var bidirectional = true
    /// Copy meeting titles and join links instead of writing opaque blockers, per
    /// direction: into the target (events from the source) and into the source.
    var detailsToTarget = false
    var detailsToSource = false
    /// When copying details, prefix titles with the originating calendar's alias.
    var prefixTitles = true
}

extension SyncLink {
    // Decode field by field so links saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncLink()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? d.sourceID
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID) ?? d.targetID
        bidirectional = try c.decodeIfPresent(Bool.self, forKey: .bidirectional) ?? d.bidirectional
        detailsToTarget = try c.decodeIfPresent(Bool.self, forKey: .detailsToTarget) ?? d.detailsToTarget
        detailsToSource = try c.decodeIfPresent(Bool.self, forKey: .detailsToSource) ?? d.detailsToSource
        prefixTitles = try c.decodeIfPresent(Bool.self, forKey: .prefixTitles) ?? d.prefixTitles
    }
}

/// One direction of a link: blockers for events in `from` are written to `to`.
struct DirectedPair: Hashable {
    let from: String
    let to: String
    var copyDetails = false
    var prefixTitles = false
}

struct SyncConfig: Codable, Equatable {
    var links: [SyncLink] = []
    var daysAhead = 30
    var intervalMinutes = 5
    var blockerTitle = "Busy"
    var mirrorTentative = true
    var paused = false
    /// Short names for calendars, keyed by calendar id, e.g. "Digacon" or "AMAG".
    /// Used in title prefixes and throughout the UI.
    var aliases: [String: String] = [:]

    init() {}

    // Decode field by field so adding a setting later doesn't wipe saved config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncConfig()
        links = try c.decodeIfPresent([SyncLink].self, forKey: .links) ?? d.links
        daysAhead = try c.decodeIfPresent(Int.self, forKey: .daysAhead) ?? d.daysAhead
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        blockerTitle = try c.decodeIfPresent(String.self, forKey: .blockerTitle) ?? d.blockerTitle
        mirrorTentative = try c.decodeIfPresent(Bool.self, forKey: .mirrorTentative) ?? d.mirrorTentative
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? d.aliases
    }

    var directedPairs: [DirectedPair] {
        var seen = Set<[String]>(), out: [DirectedPair] = []
        for l in links where !l.sourceID.isEmpty && !l.targetID.isEmpty && l.sourceID != l.targetID {
            func pair(_ from: String, _ to: String, details: Bool) -> DirectedPair {
                DirectedPair(from: from, to: to, copyDetails: details, prefixTitles: details && l.prefixTitles)
            }
            var dirs = [pair(l.sourceID, l.targetID, details: l.detailsToTarget)]
            if l.bidirectional { dirs.append(pair(l.targetID, l.sourceID, details: l.detailsToSource)) }
            // The first link for a direction wins if two links overlap.
            for d in dirs where seen.insert([d.from, d.to]).inserted { out.append(d) }
        }
        return out
    }

    func alias(for id: String) -> String? {
        let a = aliases[id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return a.isEmpty ? nil : a
    }

    private static let key = "config"

    static func load() -> SyncConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(SyncConfig.self, from: data) else { return SyncConfig() }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
