import Foundation

/// A link between two calendars. Busy time in `sourceID` is mirrored into
/// `targetID` (and the other way round when `bidirectional`).
struct SyncLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceID = ""
    var targetID = ""
    var bidirectional = true
}

/// One direction of a link: blockers for events in `from` are written to `to`.
struct DirectedPair: Hashable {
    let from: String
    let to: String
}

struct SyncConfig: Codable, Equatable {
    var links: [SyncLink] = []
    var daysAhead = 30
    var intervalMinutes = 5
    var blockerTitle = "Busy"
    var mirrorTentative = true
    var paused = false

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
    }

    var directedPairs: [DirectedPair] {
        var seen = Set<DirectedPair>(), out: [DirectedPair] = []
        for l in links where !l.sourceID.isEmpty && !l.targetID.isEmpty && l.sourceID != l.targetID {
            var dirs = [DirectedPair(from: l.sourceID, to: l.targetID)]
            if l.bidirectional { dirs.append(DirectedPair(from: l.targetID, to: l.sourceID)) }
            for d in dirs where seen.insert(d).inserted { out.append(d) }
        }
        return out
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
