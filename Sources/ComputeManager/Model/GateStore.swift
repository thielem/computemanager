import Foundation
import Shared

/// Persists gate settings + level as JSON in Application Support.
struct GateStore {
    struct Snapshot: Codable, Equatable {
        var settings: GateSettings
        var level: GateLevel
    }

    let url: URL

    static var standard: GateStore {
        GateStore(url: URL(fileURLWithPath: Paths.appSupportDirectory).appendingPathComponent("gate.json"))
    }

    /// Stop levels are not restored: after a restart, reattached jobs must not be killed or
    /// nagged again, so softStop/hardStop come back as noMore.
    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              var s = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot(settings: GateSettings(), level: .on) }
        if s.level.isOff { s.level = .noMore }
        return s
    }

    func save(_ s: Snapshot) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }
}
