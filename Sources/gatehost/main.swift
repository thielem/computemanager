// DEBUG/E2E only: headless GateService host for scripts/e2e (no GUI, no fand).
//
//   gatehost serve --socket <path> [--slots N] [--default-max <secs>] [--level on|noMore|…] [--push]
//       Hosts GateService on <path>. Logs every request ("req <json>") and every status change
//       ("status <json>") to stdout. Without --push, notices are NOT pushed to Claude Code
//       messaging sockets (hook delivery only).
//   gatehost ctl --socket <path> status | setGate <level> [slots] | killJob <uuid> [soft] | meeting
//       Sends one request, prints the reply body as JSON.
#if DEBUG
@testable import GateCore
import Foundation
import Shared

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(64)
}

func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

func json<T: Encodable>(_ v: T) -> String {
    (try? WireCoding.line(v)).map { String(decoding: $0, as: UTF8.self) } ?? "\(v)"
}

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { die("usage: gatehost serve|ctl --socket <path> …") }
args.removeFirst()
@MainActor func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
guard let socket = opt("--socket") else { die("--socket required") }

switch mode {
case "serve":
    var settings = GateSettings()
    if let s = opt("--slots").flatMap(Int.init) { settings.slots = s }
    if let m = opt("--default-max").flatMap(TimeInterval.init) { settings.defaultMaxRuntimeSeconds = m }
    let level = opt("--level").flatMap(GateLevel.init(rawValue:)) ?? .on
    let push = flag("--push")
    let service = GateService(settings: settings, level: level, clock: { Date() },
                              isAlive: GateService.pidAlive, pusher: push ? .live : .none,
                              pollWindow: Defaults.waitTicketPollWindow, autoTick: true)
    service.onChange = { out("status " + json($0)) }
    let server = GateServer(path: socket) { req, _ in
        out("req " + json(Request(req)))
        return await service.handle(req)
    }
    do { try server.start() } catch { die("gatehost: cannot serve \(socket): \(error)") }
    out("gatehost serving \(socket) pid \(getpid()) slots \(settings.slots) push \(push)")
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }
    dispatchMain()

case "ctl":
    guard let op = args.first else { die("ctl: missing op") }
    let req: GateRequest
    switch op {
    case "status": req = .status
    case "meeting": req = .meeting
    case "setGate":
        guard args.count >= 2, let l = GateLevel(rawValue: args[1]) else { die("setGate <level> [slots]") }
        req = .setGate(SetGateRequest(level: l, slots: args.count > 2 ? Int(args[2]) : nil))
    case "killJob":
        guard args.count >= 2, let id = UUID(uuidString: args[1]) else { die("killJob <uuid> [soft]") }
        req = .killJob(KillJobRequest(jobId: id, soft: args.count > 2 && args[2] == "soft" ? true : nil))
    default: die("ctl: unknown op \(op)")
    }
    do {
        let c = try GateClient(path: socket)
        defer { c.close() }
        switch try c.call(req) {
        case .status(let s), .setGate(let s), .meeting(let s), .killJob(let s), .setSettings(let s):
            out(json(s))
        case let other:
            out("\(other)")
        }
    } catch {
        die("ctl: \(error)")
    }

default:
    die("unknown mode \(mode)")
}
#else
print("gatehost is a DEBUG-only E2E tool")
#endif
