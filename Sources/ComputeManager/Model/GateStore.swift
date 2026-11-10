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
    /// An unreadable file is kept as `gate.json.bak` before the next save overwrites it.
    func load() -> Snapshot {
        let fallback = Snapshot(settings: GateSettings(), level: .on)
        guard let data = try? Data(contentsOf: url) else { return fallback }
        let decoded: Snapshot
        do {
            decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            NSLog("ComputeManager: gate.json unreadable, using defaults, kept as .bak: \(error)")
            try? data.write(to: backupURL, options: .atomic)
            return fallback
        }
        var s = decoded
        if s.level.isOff { s.level = .noMore }
        return s
    }

    var backupURL: URL { url.appendingPathExtension("bak") }

    func save(_ s: Snapshot) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }
}
