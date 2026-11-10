import Foundation

/// Typed access to SMC keys. Implemented by `AppleSMC` (IOKit) and by a fake in tests.
/// Values are converted from/to the key's own data type (from the key info: `flt `, `ui8 `, …).
protocol SMCKeyIO: AnyObject, Sendable {
    /// True if the key exists on this SMC.
    func exists(_ key: String) -> Bool
    func read(_ key: String) throws -> Double
    func write(_ key: String, _ value: Double) throws
    /// All keys starting with one of `prefixes` (enumerates `#KEY`; slow, call once).
    func keys(withPrefixes prefixes: [String]) throws -> [String]
}

struct SMCError: Error, CustomStringConvertible, Equatable {
    let description: String
    init(_ s: String) { description = s }
}

/// Converts raw SMC bytes ↔ Double, by SMC data type (4-char code incl. trailing spaces).
enum SMCCodec {
    static func decode(_ type: String, _ b: [UInt8]) throws -> Double {
        func need(_ n: Int) throws { guard b.count >= n else { throw SMCError("short value for '\(type)'") } }
        func be16() -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
        switch type {
        case "flt ":
            try need(4)
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })  // little-endian on AS
        case "ui8 ", "flag": try need(1); return Double(b[0])
        case "si8 ": try need(1); return Double(Int8(bitPattern: b[0]))
        case "ui16": try need(2); return Double(be16())
        case "si16": try need(2); return Double(Int16(bitPattern: be16()))
        case "ui32": try need(4); return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2": try need(2); return Double(be16()) / 4
        case "sp78": try need(2); return Double(Int16(bitPattern: be16())) / 256
        case "ioft":
            try need(8)
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536
        default: throw SMCError("unknown type '\(type)'")
        }
    }

    static func encode(_ type: String, _ v: Double) throws -> [UInt8] {
        guard v.isFinite else { throw SMCError("non-finite value") }
        func clamp<T: FixedWidthInteger>(_: T.Type, _ x: Double) -> T {
            T(Swift.min(Swift.max(x.rounded(), Double(T.min)), Double(T.max)))
        }
        switch type {
        case "flt ": return withUnsafeBytes(of: Float32(v)) { Array($0) }
        case "ui8 ", "flag": return [clamp(UInt8.self, v)]
        case "ui16": let x = clamp(UInt16.self, v); return [UInt8(x >> 8), UInt8(x & 0xff)]
        case "ui32": let x = clamp(UInt32.self, v); return [24, 16, 8, 0].map { UInt8((x >> $0) & 0xff) }
        case "fpe2": let x = clamp(UInt16.self, v * 4); return [UInt8(x >> 8), UInt8(x & 0xff)]
        default: throw SMCError("cannot encode type '\(type)'")
        }
    }
}
