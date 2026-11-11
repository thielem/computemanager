import Foundation
import Shared

/// Persists the performance curve as JSON (`fan.json`) in Application Support. fand keeps it in
/// memory only, so the app re-sends it with every `setMode`.
struct FanStore {
    let url: URL

    static var standard: FanStore {
        FanStore(url: URL(fileURLWithPath: Paths.appSupportDirectory).appendingPathComponent("fan.json"))
    }

    func load() -> FanCurve {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(FanCurve.self, from: data),
              let v = c.clamped(tick: Defaults.fanCurve.tick) else { return Defaults.fanCurve }
        return v
    }

    func save(_ c: FanCurve) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) }
    }
}
