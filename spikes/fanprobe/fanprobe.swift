// fanprobe — M0 spike. Throwaway. Build: ./build.sh
//   fanprobe read   (unprivileged) fans + temperature keys
//   fanprobe test   (root) [Ftst=1 if key exists], F*Md=1, F*Tg=max for <=10 s, always restore to Auto
import Foundation
import IOKit

// MARK: - SMC structs (AppleSMC SMCParamStruct, 80 bytes)

struct SMCVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
struct SMCKeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) } // explicit pad: Swift packs by size, C by stride
typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

enum Cmd: UInt8 { case read = 5, write = 6, keyFromIndex = 8, keyInfo = 9 }

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func str(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

final class SMC {
    var conn: io_connect_t = 0
    init() throws {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { throw E("AppleSMC service not found") }
        defer { IOObjectRelease(svc) }
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw E("IOServiceOpen failed: \(kr)") }
    }
    deinit { IOServiceClose(conn) }

    func call(_ input: inout SMCParam) throws -> SMCParam {
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &out, &outSize)
        guard kr == kIOReturnSuccess else { throw E("IOConnectCallStructMethod kr=\(String(format: "0x%x", kr))") }
        guard out.result == 0 else { throw E("SMC result=\(out.result)") }
        return out
    }

    func info(_ key: String) throws -> (size: Int, type: String) {
        var p = SMCParam(); p.key = fourCC(key); p.data8 = Cmd.keyInfo.rawValue
        let o = try call(&p)
        return (Int(o.keyInfo.dataSize), str(o.keyInfo.dataType))
    }

    func readRaw(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let i = try info(key)
        var p = SMCParam(); p.key = fourCC(key); p.keyInfo.dataSize = UInt32(i.size); p.data8 = Cmd.read.rawValue
        let o = try call(&p)
        let all = withUnsafeBytes(of: o.bytes) { Array($0) }
        return (i.type, Array(all.prefix(i.size)))
    }

    func read(_ key: String) throws -> Double {
        let (t, b) = try readRaw(key)
        return try decode(t, b)
    }

    func write(_ key: String, _ value: Double) throws {
        let i = try info(key)
        let b = try encode(i.type, i.size, value)
        var p = SMCParam(); p.key = fourCC(key); p.keyInfo.dataSize = UInt32(i.size); p.data8 = Cmd.write.rawValue
        withUnsafeMutableBytes(of: &p.bytes) { for (n, x) in b.enumerated() { $0[n] = x } }
        _ = try call(&p)
    }

    func keyCount() throws -> Int { Int(try read("#KEY")) }

    func key(at i: Int) throws -> String {
        var p = SMCParam(); p.data8 = Cmd.keyFromIndex.rawValue; p.data32 = UInt32(i)
        return str(try call(&p).key)
    }
}

struct E: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

func decode(_ t: String, _ b: [UInt8]) throws -> Double {
    switch t {
    case "flt ": return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) // little-endian on AS
    case "ui8 ", "flag": return Double(b[0])
    case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
    case "ui32": return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    case "si8 ": return Double(Int8(bitPattern: b[0]))
    case "si16": return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
    case "fpe2": return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
    case "sp78": return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
    case "ioft": return Double(b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536
    default: throw E("unknown type '\(t)'")
    }
}

func encode(_ t: String, _ size: Int, _ v: Double) throws -> [UInt8] {
    switch t {
    case "flt ": return withUnsafeBytes(of: Float32(v)) { Array($0) }
    case "ui8 ", "flag": return [UInt8(v)]
    case "ui16": let x = UInt16(v); return [UInt8(x >> 8), UInt8(x & 0xff)]
    case "ui32": let x = UInt32(v); return [24, 16, 8, 0].map { UInt8((x >> $0) & 0xff) }
    case "fpe2": let x = UInt16(v * 4); return [UInt8(x >> 8), UInt8(x & 0xff)]
    default: throw E("cannot encode type '\(t)' (size \(size))")
    }
}

// MARK: - Helpers

func fmt(_ smc: SMC, _ k: String) -> String {
    guard let i = try? smc.info(k) else { return "\(k)=<missing>" }
    guard let v = try? smc.read(k) else { return "\(k)=<read err>(\(i.type))" }
    return "\(k)=\(String(format: "%.1f", v))(\(i.type.trimmingCharacters(in: .whitespaces)))"
}

func fanCount(_ smc: SMC) -> Int { Int((try? smc.read("FNum")) ?? 0) }

func printFans(_ smc: SMC) {
    let n = fanCount(smc)
    print("FNum=\(n)  \(fmt(smc, "Ftst"))")
    for f in 0..<n {
        print("  fan \(f): " + ["Ac", "Mn", "Mx", "Md", "Tg"].map { fmt(smc, "F\(f)\($0)") }.joined(separator: "  "))
    }
}

// MARK: - read

func cmdRead() throws {
    let smc = try SMC()
    print("SMCParam size=\(MemoryLayout<SMCParam>.stride) (expect 80)")
    printFans(smc)
    let n = try smc.keyCount()
    var temps: [(String, String, Double)] = []
    for i in 0..<n {
        guard let k = try? smc.key(at: i), k.hasPrefix("T"), let inf = try? smc.info(k),
              let v = try? smc.read(k) else { continue }
        temps.append((k, inf.type, v))
    }
    let plausible = temps.filter { $0.2 > 5 && $0.2 < 130 }
    print("#KEY=\(n)  T* keys readable=\(temps.count)  plausible(5..130)=\(plausible.count)")
    for prefix in ["Tp", "Te", "Tg"] {
        let g = plausible.filter { $0.0.hasPrefix(prefix) }
        print("\(prefix)* (\(g.count)): " + g.map { "\($0.0)=\(String(format: "%.1f", $0.2))" }.joined(separator: " "))
    }
    let other = plausible.filter { !["Tp", "Te", "Tg"].contains(String($0.0.prefix(2))) }
    print("other T* (\(other.count)): " + other.map { "\($0.0)=\(String(format: "%.1f", $0.2))" }.joined(separator: " "))
}

// MARK: - test (root)

func hasFtst(_ smc: SMC) -> Bool { (try? smc.info("Ftst")) != nil }

var restoreSMC: SMC?
var restored = false
func restore() {
    guard let smc = restoreSMC, !restored else { return }
    restored = true
    for f in 0..<fanCount(smc) {
        do { try smc.write("F\(f)Md", 0) } catch { print("restore F\(f)Md=0 failed: \(error)") }
    }
    if hasFtst(smc) { do { try smc.write("Ftst", 0) } catch { print("restore Ftst=0 failed: \(error)") } }
    print("restored: F*Md=0" + (hasFtst(smc) ? ", Ftst=0" : " (no Ftst key)"))
}

func cmdTest() throws {
    guard getuid() == 0 else { throw E("test needs root: sudo \(CommandLine.arguments[0]) test") }
    let smc = try SMC()
    restoreSMC = smc
    for s in [SIGINT, SIGTERM, SIGHUP] {
        signal(s) { _ in restore(); exit(130) }
    }
    defer { restore() }

    print("== before"); printFans(smc)
    let n = fanCount(smc)
    guard n > 0 else { throw E("no fans") }
    let start = (0..<n).map { (try? smc.read("F\($0)Ac")) ?? 0 }
    let maxes = (0..<n).map { (try? smc.read("F\($0)Mx")) ?? 0 }

    if hasFtst(smc) { try smc.write("Ftst", 1); print("Ftst=1 ok") } else { print("no Ftst key on this SMC: writing F*Md directly") }
    for f in 0..<n {
        // On Apple Silicon the Md write may be rejected until thermalmonitord lets go after Ftst=1: retry up to 3 s.
        var ok = false
        for attempt in 1...30 {
            do { try smc.write("F\(f)Md", 1); ok = true; print("F\(f)Md=1 ok (attempt \(attempt))"); break }
            catch { if attempt == 30 { print("F\(f)Md=1 failed: \(error)") }; usleep(100_000) }
        }
        if ok { try smc.write("F\(f)Tg", maxes[f]); print("F\(f)Tg=\(maxes[f]) ok") }
    }

    var peak = start
    for t in 1...10 {
        sleep(1)
        let ac = (0..<n).map { (try? smc.read("F\($0)Ac")) ?? 0 }
        for f in 0..<n { peak[f] = max(peak[f], ac[f]) }
        print("t=\(t)s Ac=" + ac.map { String(format: "%.0f", $0) }.joined(separator: ","))
        if (0..<n).allSatisfy({ ac[$0] >= maxes[$0] * 0.9 }) { break }
    }

    restore()
    sleep(1)
    print("== after"); printFans(smc)
    let rose = (0..<n).allSatisfy { peak[$0] - start[$0] >= max(800, (maxes[$0] - start[$0]) * 0.4) }
    let auto = (0..<n).allSatisfy { ((try? smc.read("F\($0)Md")) ?? -1) == 0 }
        && (!hasFtst(smc) || ((try? smc.read("Ftst")) ?? -1) == 0)
    print("start=\(start.map { Int($0) }) peak=\(peak.map { Int($0) }) max=\(maxes.map { Int($0) })")
    print(rose && auto ? "PASS" : "FAIL (rose=\(rose) auto=\(auto))")
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "read": try cmdRead()
    case "test": try cmdTest()
    case "keys": // fanprobe keys <prefix>: dump matching keys (type, raw hex, value)
        let smc = try SMC(), pre = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "F"
        for i in 0..<(try smc.keyCount()) {
            guard let k = try? smc.key(at: i), k.hasPrefix(pre) else { continue }
            let r = try? smc.readRaw(k)
            let v = r.flatMap { try? decode($0.type, $0.bytes) }.map { String(format: "%.2f", $0) } ?? "?"
            print("\(k) \(r?.type ?? "?") \(r?.bytes.map { String(format: "%02x", $0) }.joined() ?? "<read err>") \(v)")
        }
    default: print("usage: fanprobe read|test|keys [prefix]"); exit(2)
    }
} catch {
    print("error: \(error)"); restore(); exit(1)
}
