import Foundation
@testable import fand
import Shared

/// In-memory SMC. Records every write. Never touches hardware.
final class FakeSMC: SMCKeyIO, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var values: [String: Double]
    private(set) var writes: [(String, Double)] = []
    var failWrites = false

    init(fans: Int = 2, ftst: Bool = false, temps: [String: Double] = ["Tp01": 50, "Tp05": 48, "Te05": 40, "Tg0f": 45]) {
        var v: [String: Double] = ["FNum": Double(fans), "#KEY": 0]
        for f in 0..<fans {
            v["F\(f)Mn"] = 2317; v["F\(f)Mx"] = 6800; v["F\(f)Ac"] = 2400; v["F\(f)Md"] = 0; v["F\(f)Tg"] = 2317
        }
        if ftst { v["Ftst"] = 0 }
        for (k, t) in temps { v[k] = t }
        values = v
    }

    func exists(_ key: String) -> Bool { locked { values[key] != nil } }

    func read(_ key: String) throws -> Double {
        try locked {
            guard let v = values[key] else { throw SMCError("missing \(key)") }
            return v
        }
    }

    func write(_ key: String, _ value: Double) throws {
        try locked {
            guard !failWrites else { throw SMCError("write failed") }
            guard values[key] != nil else { throw SMCError("missing \(key)") }
            values[key] = value
            writes.append((key, value))
        }
    }

    func keys(withPrefixes prefixes: [String]) throws -> [String] {
        locked { values.keys.filter { k in prefixes.contains { k.hasPrefix($0) } }.sorted() }
    }

    /// Test helpers.
    func set(_ key: String, _ value: Double) { locked { values[key] = value } }
    func value(_ key: String) -> Double? { locked { values[key] } }
    func clearWrites() { locked { writes.removeAll() } }
    var writeLog: [(String, Double)] { locked { writes } }
    /// Simulate the SMC dropping manual control (e.g. after wake).
    func resetFans() { locked { for k in values.keys where k.hasSuffix("Md") { values[k] = 0 } } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Thread-safe thermal state box for tests.
final class ThermalBox: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var s: ThermalState = .nominal
    var value: ThermalState {
        get { lock.lock(); defer { lock.unlock() }; return s }
        set { lock.lock(); s = newValue; lock.unlock() }
    }
}
