import Foundation
import IOKit

// Real SMC access via IOKit AppleSMC (struct method selector 2). Reads work unprivileged;
// writes need root. Verified on an M2 Pro MacBook Pro.

private struct SMCVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
// Explicit pad: Swift packs nested structs by size, C by stride. SMCParam must be 80 bytes.
private struct SMCKeyInfoRaw { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfoRaw()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum Cmd: UInt8 { case read = 5, write = 6, keyFromIndex = 8, keyInfo = 9 }

func smcFourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func smcString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

final class AppleSMC: SMCKeyIO, @unchecked Sendable {  // all IOKit calls + cache guarded by `lock`
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [String: (size: Int, type: String)] = [:]

    static var paramSize: Int { MemoryLayout<SMCParam>.stride }

    init() throws {
        precondition(Self.paramSize == 80, "SMCParam must be 80 bytes")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { throw SMCError("AppleSMC service not found") }
        defer { IOObjectRelease(svc) }
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError("IOServiceOpen failed: \(kr)") }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCParam) throws -> SMCParam {
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &out, &outSize)
        guard kr == kIOReturnSuccess else { throw SMCError("IOConnectCallStructMethod kr=\(String(format: "0x%x", kr))") }
        guard out.result == 0 else { throw SMCError("SMC result=\(out.result)") }
        return out
    }

    private func info(_ key: String) throws -> (size: Int, type: String) {
        if let i = infoCache[key] { return i }
        var p = SMCParam()
        p.key = smcFourCC(key)
        p.data8 = Cmd.keyInfo.rawValue
        let o = try call(&p)
        let i = (Int(o.keyInfo.dataSize), smcString(o.keyInfo.dataType))
        guard i.0 > 0, i.0 <= 32 else { throw SMCError("bad size \(i.0) for \(key)") }
        infoCache[key] = i
        return i
    }

    func exists(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? info(key)) != nil
    }

    func read(_ key: String) throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        let i = try info(key)
        var p = SMCParam()
        p.key = smcFourCC(key)
        p.keyInfo.dataSize = UInt32(i.size)
        p.data8 = Cmd.read.rawValue
        let o = try call(&p)
        let all = withUnsafeBytes(of: o.bytes) { Array($0) }
        return try SMCCodec.decode(i.type, Array(all.prefix(i.size)))
    }

    func write(_ key: String, _ value: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        let i = try info(key)
        let b = try SMCCodec.encode(i.type, value)
        guard b.count == i.size else { throw SMCError("size mismatch for \(key)") }
        var p = SMCParam()
        p.key = smcFourCC(key)
        p.keyInfo.dataSize = UInt32(i.size)
        p.data8 = Cmd.write.rawValue
        withUnsafeMutableBytes(of: &p.bytes) { for (n, x) in b.enumerated() { $0[n] = x } }
        _ = try call(&p)
    }

    func keys(withPrefixes prefixes: [String]) throws -> [String] {
        let n = Int(try read("#KEY"))
        lock.lock()
        defer { lock.unlock() }
        var out: [String] = []
        for i in 0..<n {
            var p = SMCParam()
            p.data8 = Cmd.keyFromIndex.rawValue
            p.data32 = UInt32(i)
            guard let k = try? smcString(call(&p).key) else { continue }
            if prefixes.contains(where: { k.hasPrefix($0) }) { out.append(k) }
        }
        return out
    }
}
