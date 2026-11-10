import Darwin
import Foundation
import Testing
@testable import cgate
@testable import GateCore
import Shared

final class Clock: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var t = Date()
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class Lines: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// In-process GateService on a /tmp/cm-test-*.sock path (fake clock, no real pushes).
final class Harness {
    let path = "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    let clock = Clock()
    let svc: GateService
    let server: GateServer
    let stderr = Lines()

    init(slots: Int = 1, level: GateLevel = .on) throws {
        let clock = clock
        svc = GateService(settings: GateSettings(slots: slots), level: level, clock: { clock.now },
                          isAlive: { _ in true }, pusher: .none, pollWindow: 0.3, pollStep: 0.02,
                          autoTick: false)
        server = svc.makeServer(path: path)
        try server.start()
    }

    deinit { server.stop() }

    var link: GateLink { GateLink(path: path) }

    func ctx(log: String = "/tmp/cm-test-unused.log") -> RunContext {
        let lines = stderr
        return RunContext(link: link, env: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
                          cwd: "/tmp/proj", heartbeatInterval: 0.05, killGrace: 0.3,
                          fallbackLog: log, stderr: { lines.add($0) })
    }

    func status() async -> GateStatus {
        guard case .success(.status(let s)) = await svc.handle(.status) else { fatalError("status") }
        return s
    }
}

/// Run blocking work on its own thread (never block the cooperative pool the server needs).
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread.detachNewThread { c.resume(returning: body()) } }
}

func opts(_ cmd: [String], max: TimeInterval? = nil, ticket: String? = nil) -> RunOptions {
    RunOptions(maxRuntime: max, session: "sess", ticket: ticket, command: cmd)
}

func eventually(_ timeout: TimeInterval = 5, _ cond: () async -> Bool) async -> Bool {
    let end = Date() + timeout
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await cond()
}

@Suite(.serialized) struct RunTests {
    @Test func grantedRunPropagatesExitCodeAndReleases() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        #expect(await offPool { Runner.run(opts(["sleep 0.2; exit 3"]), ctx) } == 3)
        #expect(await offPool { Runner.run(opts(["/bin/sh", "-c", "exit 0"]), ctx) } == 0)
        let s = await h.status()
        #expect(s.leases.isEmpty)
    }

    @Test func busyAndOffExitCodes() async throws {
        let h = try Harness(slots: 0)
        let ctx = h.ctx()
        #expect(await offPool { Runner.run(opts(["true"]), ctx) } == CgateExit.busy)
        #expect(h.stderr.all.last?.hasPrefix("compute busy: ticket t1, position 1") == true)
        #expect(await offPool { Runner.run(opts(["true"], ticket: "t9"), ctx) } == CgateExit.ticketExpired)
        _ = await h.svc.handle(.setGate(SetGateRequest(level: .noMore)))
        #expect(await offPool { Runner.run(opts(["true"]), ctx) } == CgateExit.gateOff)
        #expect(h.stderr.all.last == CgateMessage.gateOff)
    }

    @Test func hardStopKillsProcessGroup() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        async let code = offPool { Runner.run(opts(["sleep 30 & sleep 30; wait"]), ctx) }
        #expect(await eventually { await h.status().leases.first?.pgid != nil })
        let pgid = try #require(await h.status().leases.first?.pgid)
        #expect(kill(-pgid, 0) == 0)
        _ = await h.svc.handle(.setGate(SetGateRequest(level: .hardStop)))
        #expect(await code == CgateExit.stoppedByUser)
        #expect(h.stderr.all.last == CgateMessage.stoppedByUser)
        #expect(kill(-pgid, 0) == -1 && errno == ESRCH)
        #expect(await h.status().leases.isEmpty)
    }

    @Test func hardStopKillsTermIgnoringGrandchild() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        // The shell dies on TERM; the grandchild ignores it and must still die (H1).
        async let code = offPool { Runner.run(opts(["(trap '' TERM; sleep 30) & wait"]), ctx) }
        #expect(await eventually { await h.status().leases.first?.pgid != nil })
        let pgid = try #require(await h.status().leases.first?.pgid)
        defer { kill(-pgid, SIGKILL) }
        let id = try #require(await h.status().leases.first?.jobId)
        _ = await h.svc.handle(.killJob(KillJobRequest(jobId: id)))
        #expect(await code == CgateExit.stoppedByUser)
        #expect(await eventually(2) { kill(-pgid, 0) == -1 && errno == ESRCH })
    }

    @Test func forwarderEscalatesAndDeliversEarlySignal() async throws {
        for early in [false, true] {
            let pid = try #require(Runner.spawn(["/bin/sh", "-c", "trap '' TERM; sleep 30"], env: [:]))
            let f = Forwarder(grace: 0.2)
            let p = pid
            Thread.detachNewThread { var st: Int32 = 0; waitpid(p, &st, 0); f.markExited() }
            if early { f.forward(SIGTERM); f.started(pid) } else { f.started(pid); f.forward(SIGTERM) }
            #expect(f.signal == SIGTERM)
            #expect(await eventually(3) { kill(-p, 0) == -1 && errno == ESRCH })
        }
    }

    @Test func signalAfterChildExitIsNotRecorded() {
        let f = Forwarder(grace: 0.2)
        f.started(999_999)
        f.markExited()
        f.forward(SIGINT)
        #expect(f.signal == nil)
    }

    @Test func shellChoice() {
        #expect(Runner.shell(["SHELL": "/bin/zsh"]) == "/bin/zsh")
        #expect(Runner.shell(["SHELL": "/opt/homebrew/bin/bash"]) == "/opt/homebrew/bin/bash")
        #expect(Runner.shell(["SHELL": "/opt/homebrew/bin/fish"]) == "/bin/bash")
        #expect(Runner.shell(["SHELL": "zsh"]) == "/bin/bash")
        #expect(Runner.shell([:]) == "/bin/bash")
    }

    @Test func sessionFallbackFromSessionsDir() throws {
        let dir = NSTemporaryDirectory() + "cm-sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(#"{"sessionId":"abc"}"#.utf8).write(to: URL(fileURLWithPath: dir + "/999999.json"))
        #expect(SessionLookup.resolve(env: ["CLAUDE_CODE_SESSION_ID": "env"], sessionsDir: dir) == "env")
        #expect(SessionLookup.resolve(env: ["CLAUDE_PID": "999999"], sessionsDir: dir) == "abc")
        #expect(SessionLookup.resolve(env: [:], sessionsDir: dir) == "unknown")
    }

    @Test func sigkillAfterGraceWhenTermIgnored() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        let start = Date()
        async let code = offPool { Runner.run(opts(["trap '' TERM; sleep 20; sleep 20"]), ctx) }
        #expect(await eventually { await h.status().leases.first?.pgid != nil })
        let id = try #require(await h.status().leases.first?.jobId)
        _ = await h.svc.handle(.killJob(KillJobRequest(jobId: id)))
        #expect(await code == CgateExit.stoppedByUser)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func walltimeSoftThenKill() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        async let code = offPool { Runner.run(opts(["sleep 30"], max: 60), ctx) }
        #expect(await eventually { await h.status().leases.first?.pgid != nil })
        h.clock.advance(60)
        #expect(await eventually { h.stderr.all.contains { $0.contains("exceeded its declared max runtime (1m)") } })
        h.clock.advance(60)
        #expect(await code == CgateExit.walltimeKill)
        #expect(h.stderr.all.last == CgateMessage.walltimeKilled(max: 60))
    }

    @Test func softStopPrintsNoticeAndKeepsRunning() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        async let code = offPool { Runner.run(opts(["sleep 0.6"]), ctx) }
        #expect(await eventually { await h.status().leases.count == 1 })
        _ = await h.svc.handle(.setGate(SetGateRequest(level: .softStop)))
        #expect(await code == 0)
        #expect(h.stderr.all == [CgateMessage.softStopNotice])
    }

    @Test func reattachAfterAppRestart() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        async let code = offPool { Runner.run(opts(["sleep 1"]), ctx) }
        #expect(await eventually { await h.status().leases.count == 1 })
        let jobId = try #require(await h.status().leases.first?.jobId)
        // "Restart": a fresh service takes over the same socket path.
        h.server.stop()
        let fresh = GateService(settings: GateSettings(slots: 0), level: .on, clock: { Date() },
                                isAlive: { _ in true }, pusher: .none, pollWindow: 0.3, autoTick: false)
        let server2 = fresh.makeServer(path: h.path)
        try server2.start()
        defer { server2.stop() }
        #expect(await eventually {
            guard case .success(.status(let s)) = await fresh.handle(.status) else { return false }
            return s.leases.first?.jobId == jobId
        })
        #expect(await code == 0)
    }

    @Test func ungatedWhenAppUnreachable() async throws {
        let log = "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        var ctx = try Harness().ctx(log: log)
        ctx.link = GateLink(path: "/tmp/cm-test-nonexistent-\(getpid()).sock")
        let c = ctx
        #expect(await offPool { Runner.run(opts(["exit 4"]), c) } == 4)
        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(text.contains("ungated session=sess project=proj cmd=exit 4"))
    }

    @Test func waitReadyAndExpired() async throws {
        let h = try Harness()
        let ctx = h.ctx()
        let link = h.link, lines = h.stderr
        async let first = offPool { Runner.run(opts(["sleep 0.5"]), ctx) }
        #expect(await eventually { await h.status().leases.count == 1 })
        var o2 = opts(["true"])
        o2.session = "other"
        let o = o2
        #expect(await offPool { Runner.run(o, ctx) } == CgateExit.busy)
        #expect(await offPool { Waiter.run(ticket: "t1", link: link, stderr: { lines.add($0) }) } == 0)
        #expect(lines.all.last?.hasPrefix("slot ready (ticket t1, held until") == true)
        #expect(await first == 0)
        #expect(await offPool { Runner.run(RunOptions(maxRuntime: nil, session: "other", ticket: "t1",
                                                      command: ["true"]), ctx) } == 0)
        #expect(await offPool { Waiter.run(ticket: "t1", link: link, stderr: { lines.add($0) }) } == CgateExit.ticketExpired)
    }

    @Test func exitCodeDecoding() {
        #expect(Runner.exitCode(3 << 8) == 3)
        #expect(Runner.exitCode(SIGKILL) == 137)
    }
}

@Suite(.serialized) struct HookTests {
    let input: [String: Any] = [
        "session_id": "sess", "cwd": "/tmp/proj", "hook_event_name": "PreToolUse", "tool_name": "Bash",
        "tool_input": ["command": "swift test", "description": "Run tests", "timeout": 600000,
                       "run_in_background": true],
    ]

    func json(_ d: Data?) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: try #require(d)) as? [String: Any]
        return try #require(obj?["hookSpecificOutput"] as? [String: Any])
    }

    @Test func heavyUnwrappedDeniedWithRedirect() async throws {
        let h = try Harness(slots: 0)  // busy/off doesn't matter: the hook only redirects
        let stdin = try JSONSerialization.data(withJSONObject: input)
        let link = h.link
        let out = try json(await offPool { Hook.output(stdin: stdin, link: link) })
        #expect(out["hookEventName"] as? String == "PreToolUse")
        #expect(out["permissionDecision"] as? String == "deny")
        #expect(out["updatedInput"] == nil)
        #expect(out["permissionDecisionReason"] as? String
            == "Compute gate: heavy command. Re-run as: cgate run --max <estimate> -- 'swift test' "
            + "with run_in_background: true")
        #expect(await h.status().tickets.isEmpty)
    }

    @Test func wrappedAndOtherToolsGetNoOutput() async throws {
        let h = try Harness()
        let link = h.link
        var wrapped = input
        wrapped["tool_input"] = ["command": "cgate run --max 10m -- 'cd x && swift test'"]
        let s1 = try JSONSerialization.data(withJSONObject: wrapped)
        #expect(await offPool { Hook.output(stdin: s1, link: link) } == nil)
        var other = input
        other["tool_name"] = "Read"
        other["tool_input"] = ["file_path": "/x"]
        let s2 = try JSONSerialization.data(withJSONObject: other)
        #expect(await offPool { Hook.output(stdin: s2, link: link) } == nil)
    }

    @Test func noticeDeniesOnce() async throws {
        let h = try Harness(slots: 1)
        _ = await h.svc.handle(.acquire(AcquireRequest(sessionId: "sess", cwd: "/x", command: "make", pid: 1)))
        _ = await h.svc.handle(.setGate(SetGateRequest(level: .softStop)))
        var other = input
        other["tool_name"] = "Edit"
        other["tool_input"] = ["file_path": "/x"]
        let stdin = try JSONSerialization.data(withJSONObject: other)
        let link = h.link
        let out = try json(await offPool { Hook.output(stdin: stdin, link: link) })
        #expect(out["permissionDecision"] as? String == "deny")
        #expect(out["permissionDecisionReason"] as? String == CgateMessage.softStopNotice)
        #expect(await offPool { Hook.output(stdin: stdin, link: link) } == nil)
    }

    /// App unreachable → no output even for a heavy unwrapped command (exit 0 in main).
    @Test func failOpen() async throws {
        let link = GateLink(path: "/tmp/cm-test-nonexistent-\(getpid()).sock")
        let stdin = try JSONSerialization.data(withJSONObject: input)
        let start = Date()
        #expect(await offPool { Hook.output(stdin: stdin, link: link) } == nil)
        #expect(await offPool { Hook.output(stdin: Data("garbage".utf8), link: link) } == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func renderFixtures() throws {
        #expect(Hook.render(.allow) == nil)
        #expect(Hook.render(.wrap(newCommand: "cgate run -- x")) == nil)  // never rewrite / allow
        let deny = String(decoding: try #require(Hook.render(.deny(reason: "no"))), as: UTF8.self)
        #expect(deny == #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}"#)
    }

    @Test func statusRender() {
        let now = Date()
        let s = GateStatus(level: .on, slots: 2, effectiveSlots: 2,
                           leases: [Lease(sessionId: "abcdef123456", cwd: "/p/proj", command: "make", pid: 1,
                                          pgid: 2, startedAt: now - 90, maxRuntimeSeconds: 900, autoWrapped: true)],
                           tickets: [], heldSlot: nil, nextSlotETA: nil, pendingNotices: [], settings: GateSettings())
        #expect(StatusCommand.render(s, now: now) == "gate on, slots 1/2\n  proj [abcdef12] 1m30s/15m running  make")
    }
}
