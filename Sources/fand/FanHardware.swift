import Foundation
import Shared

/// Static fan description discovered at startup.
struct FanSpec: Equatable, Sendable {
    let id: Int
    let minRPM: Double
    let maxRPM: Double
}

/// Fan + temperature access on top of `SMCKeyIO`. The ONLY place fand writes SMC keys:
/// writes go through `writeAllowed`, which accepts only `F{n}Md`, `F{n}Tg` and `Ftst`
/// (PLAN §9), and targets are clamped to `[F{n}Mn, F{n}Mx]`.
final class FanHardware: Sendable {
    let smc: SMCKeyIO
    let fans: [FanSpec]
    let hasFtst: Bool
    let pcoreKeys: [String]
    let ecoreKeys: [String]
    let gpuKeys: [String]

    /// Plausible temperature range in °C; values outside are ignored (missing/garbage sensors).
    static let plausibleTemp: ClosedRange<Double> = 5...130

    init(smc: SMCKeyIO, fans: [FanSpec], hasFtst: Bool,
         pcoreKeys: [String], ecoreKeys: [String], gpuKeys: [String]) {
        self.smc = smc
        self.fans = fans
        self.hasFtst = hasFtst
        self.pcoreKeys = pcoreKeys
        self.ecoreKeys = ecoreKeys
        self.gpuKeys = gpuKeys
    }

    /// Discover fans (`FNum`, `F{n}Mn/Mx`), `Ftst` presence and temperature keys (`Tp*` P-core,
    /// `Te*` E-core, `Tg*` GPU). Fans with unreadable or nonsensical min/max are skipped.
    static func discover(_ smc: SMCKeyIO) -> FanHardware {
        let n = Int((try? smc.read("FNum")) ?? 0)
        var fans: [FanSpec] = []
        for f in 0..<min(max(n, 0), 10) {
            guard let mn = try? smc.read("F\(f)Mn"), let mx = try? smc.read("F\(f)Mx"),
                  mn >= 0, mx > mn, mx < 20_000 else { continue }
            fans.append(FanSpec(id: f, minRPM: mn, maxRPM: mx))
        }
        let temps = (try? smc.keys(withPrefixes: ["Tp", "Te", "Tg"])) ?? []
        return FanHardware(smc: smc, fans: fans, hasFtst: smc.exists("Ftst"),
                           pcoreKeys: temps.filter { $0.hasPrefix("Tp") },
                           ecoreKeys: temps.filter { $0.hasPrefix("Te") },
                           gpuKeys: temps.filter { $0.hasPrefix("Tg") })
    }

    // MARK: Writes (allowlisted)

    static func isAllowedWrite(_ key: String) -> Bool {
        if key == "Ftst" { return true }
        let u = Array(key.utf8)
        guard u.count == 4, u[0] == UInt8(ascii: "F"), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(u[1])
        else { return false }
        let suffix = String(decoding: u[2...], as: UTF8.self)
        return suffix == "Md" || suffix == "Tg"
    }

    private func writeAllowed(_ key: String, _ value: Double) throws {
        guard Self.isAllowedWrite(key) else { throw SMCError("write to \(key) not allowed") }
        try smc.write(key, value)
    }

    /// Return all fans to Apple control: `F{n}Md=0` for every fan, then `Ftst=0` if the key
    /// exists. Tries every key even if some fail; returns the errors.
    @discardableResult
    func setAuto() -> [String] {
        var errors: [String] = []
        for f in fans {
            do { try writeAllowed("F\(f.id)Md", 0) } catch { errors.append("F\(f.id)Md=0: \(error)") }
        }
        if hasFtst {
            do { try writeAllowed("Ftst", 0) } catch { errors.append("Ftst=0: \(error)") }
        }
        return errors
    }

    /// Force each fan to `targets[id]` (clamped to [Mn, Mx]). Writes `Ftst=1` (if present) and
    /// `F{n}Md=1` only when the fan is not already manual, and `F{n}Tg` only when it differs from
    /// the current target by > 1 RPM. This also re-applies after the SMC reset itself (wake).
    @discardableResult
    func setManual(_ targets: [Int: Double], current: [FanInfo]) -> [String] {
        var errors: [String] = []
        let needsMd = fans.contains { f in current.first { $0.id == f.id }?.control != .manual }
        if needsMd, hasFtst {
            do { try writeAllowed("Ftst", 1) } catch { errors.append("Ftst=1: \(error)") }
        }
        for f in fans {
            guard let t = targets[f.id] else { continue }
            let target = min(max(t, f.minRPM), f.maxRPM)
            let cur = current.first { $0.id == f.id }
            if cur?.control != .manual {
                do { try writeAllowed("F\(f.id)Md", 1) } catch { errors.append("F\(f.id)Md=1: \(error)"); continue }
            }
            if cur?.control != .manual || cur?.targetRPM.map({ abs($0 - target) > 1 }) ?? true {
                do { try writeAllowed("F\(f.id)Tg", target) } catch { errors.append("F\(f.id)Tg: \(error)") }
            }
        }
        return errors
    }

    // MARK: Reads

    func readFans() -> [FanInfo] {
        fans.map { f in
            let md = try? smc.read("F\(f.id)Md")
            return FanInfo(id: f.id, actualRPM: (try? smc.read("F\(f.id)Ac")) ?? 0,
                           minRPM: f.minRPM, maxRPM: f.maxRPM,
                           targetRPM: try? smc.read("F\(f.id)Tg"),
                           control: (md ?? 0) == 0 ? .auto : .manual)
        }
    }

    private func hottest(_ keys: [String]) -> Double? {
        keys.compactMap { try? smc.read($0) }.filter { Self.plausibleTemp.contains($0) }.max()
    }

    func readTemps() -> Temperatures {
        Temperatures(pcoreMax: hottest(pcoreKeys), ecoreMax: hottest(ecoreKeys), gpuMax: hottest(gpuKeys))
    }
}
