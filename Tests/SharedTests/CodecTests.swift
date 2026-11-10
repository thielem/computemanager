import Foundation
import Testing
@testable import Shared

private func roundTrip<M: OpMessage>(_ req: Request<M>) throws -> Request<M> {
    try WireCoding.decode(Request<M>.self, line: WireCoding.line(req))
}

private func roundTrip<M: OpMessage>(_ r: Response<M>) throws -> Response<M> {
    try WireCoding.decode(Response<M>.self, line: WireCoding.line(r))
}

private func json(_ v: some Encodable) throws -> String {
    String(decoding: try WireCoding.line(v), as: UTF8.self)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct EnvelopeTests {
    @Test func requestWireShape() throws {
        let r = Request(id: "1", GateRequest.setGate(SetGateRequest(level: .noMore, slots: 0)))
        #expect(try json(r) == #"{"body":{"level":"noMore","slots":0},"id":"1","op":"setGate","v":1}"#)
        #expect(try json(Request(id: "2", GateRequest.status)) == #"{"id":"2","op":"status","v":1}"#)
    }

    @Test func responseWireShape() throws {
        let ok = Response(id: "1", GateReply.hookCheck(.wrap(newCommand: "cgate run -- make")))
        #expect(try json(ok) == #"{"body":{"kind":"wrap","newCommand":"cgate run -- make"},"id":"1","ok":true,"op":"hookCheck","v":1}"#)
        let err = Response<GateReply>(id: "1", op: "acquire", error: .notImplemented("acquire"))
        #expect(try json(err) == #"{"error":{"code":"notImplemented","message":"op 'acquire' not implemented"},"id":"1","ok":false,"op":"acquire","v":1}"#)
    }

    @Test func rejectsWrongVersionAndUnknownOp() {
        #expect(throws: WireError.self) {
            try WireCoding.decode(Request<GateRequest>.self, line: Data(#"{"v":2,"id":"1","op":"status"}"#.utf8))
        }
        #expect(throws: WireError(.unknownOp, "nope")) {
            try WireCoding.decode(Request<GateRequest>.self, line: Data(#"{"v":1,"id":"1","op":"nope"}"#.utf8))
        }
    }

    @Test func gateRequestsRoundTrip() throws {
        let reqs: [GateRequest] = [
            .acquire(AcquireRequest(sessionId: "s", cwd: "/p", command: "make", pid: 10, pgid: nil,
                                    maxRuntimeSeconds: 900, ticket: "t1", autoWrapped: true,
                                    messagingSocket: "/tmp/m")),
            .release(ReleaseRequest(jobId: UUID(), exitCode: 2, reason: .exited)),
            .heartbeat(JobHeartbeatRequest(jobId: UUID(), pgid: 42)),
            .hookCheck(HookCheckRequest(sessionId: "s", toolName: "Bash", command: "ls", cwd: "/p")),
            .waitTicket(WaitTicketRequest(ticket: "t1")),
            .status,
            .setGate(SetGateRequest(level: .hardStop)),
            .meeting,
            .killJob(KillJobRequest(jobId: UUID())),
            .setSettings(GateSettings(slots: 3, patterns: ["make"], defaultMaxRuntimeSeconds: 60,
                                      maxRuntimeCapSeconds: 120)),
            .acquire(AcquireRequest(sessionId: "s", cwd: "/p", command: "make", pid: 10, pgid: 11,
                                    maxRuntimeSeconds: 900,
                                    reattach: Reattach(jobId: UUID(), startedAt: t0))),
        ]
        for m in reqs {
            let r = Request(id: "x", m)
            #expect(try roundTrip(r) == r)
        }
    }

    @Test func gateRepliesRoundTrip() throws {
        let lease = Lease(sessionId: "s", cwd: "/a/proj", command: "make", pid: 1, pgid: 2,
                          startedAt: t0, maxRuntimeSeconds: 900, autoWrapped: false,
                          state: .stopRequested, stopRequestedAt: t0, stopReason: .walltime)
        let status = GateStatus(level: .softStop, slots: 2, effectiveSlots: 0, leases: [lease],
                                tickets: [TicketInfo(id: "t1", position: 1, eta: t0)],
                                heldSlot: HeldSlot(ticketId: "t1", until: t0), nextSlotETA: t0,
                                pendingNotices: [PendingNotice(sessionId: "s", text: "stop")],
                                settings: GateSettings())
        let replies: [GateReply] = [
            .acquire(.granted(jobId: UUID(), maxRuntimeSeconds: 900)),
            .acquire(.busy(TicketInfo(id: "t1", position: 2, eta: t0))),
            .acquire(.busy(TicketInfo(id: "t1", position: 2, eta: nil))),
            .acquire(.off(message: CgateMessage.gateOff)),
            .acquire(.ticketExpired(ticket: "t1")),
            .release,
            .heartbeat(.continue), .heartbeat(.softStop(reason: .userSoftStop)),
            .heartbeat(.hardStop(reason: .walltime)), .heartbeat(.unknownJob),
            .hookCheck(.allow), .hookCheck(.wrap(newCommand: "x")), .hookCheck(.deny(reason: "r")),
            .hookCheck(.notice(text: "n")),
            .waitTicket(.ready(ticket: "t1", heldUntil: t0)), .waitTicket(.expired(ticket: "t1")),
            .waitTicket(.pending(TicketInfo(id: "t1", position: 1, eta: t0))),
            .status(status), .setGate(status), .meeting(status), .killJob(status),
            .setSettings(status),
        ]
        for m in replies {
            let r = Response(id: "x", m)
            #expect(try roundTrip(r) == r)
        }
        #expect(lease.project == "proj")
    }

    @Test func fanMessagesRoundTrip() throws {
        let st = FanStatus(mode: .performance,
                           fans: [FanInfo(id: 0, actualRPM: 2400, minRPM: 1200, maxRPM: 5700,
                                          targetRPM: 2500, control: .manual)],
                           temps: Temperatures(pcoreMax: 70.5), thermalState: .fair, lastHeartbeat: t0)
        for m: FanRequest in [.status, .setMode(SetModeRequest(mode: .max)), .heartbeat, .subscribe] {
            let r = Request(id: "x", m)
            #expect(try roundTrip(r) == r)
        }
        for m: FanReply in [.status(st), .setMode(st), .heartbeat, .subscribe(st)] {
            let r = Response(id: "x", m)
            #expect(try roundTrip(r) == r)
        }
        #expect(ThermalState.serious >= .serious && ThermalState.fair < .serious)
    }
}

@Suite struct CgateContractTests {
    @Test func exitCodes() {
        #expect([CgateExit.usage, CgateExit.busy, CgateExit.gateOff, CgateExit.walltimeKill,
                 CgateExit.stoppedByUser, CgateExit.ticketExpired] == [64, 75, 76, 77, 78, 79])
        #expect(CgateExit.forHardStop(.walltime) == 77)
        #expect(CgateExit.forHardStop(.userHardStop) == 78)
        #expect(CgateExit.forHardStop(.userKill) == 78)
    }

    @Test func messages() {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 2; c.hour = 9; c.minute = 5
        let d = Calendar.current.date(from: c)!
        #expect(CgateMessage.busy(TicketInfo(id: "t3", position: 2, eta: d)) ==
            "compute busy: ticket t3, position 2, next slot ~09:05. Run in background: cgate wait --ticket t3; do other work meanwhile")
        #expect(CgateMessage.busy(TicketInfo(id: "t3", position: 1, eta: nil)).contains("next slot ~?."))
        #expect(CgateMessage.walltimeKilled(max: 900) == "killed: exceeded declared max runtime (15m)")
        #expect(CgateMessage.ticketExpired("t3") == "ticket t3 expired; retry cgate run")
        #expect(CgateMessage.slotReady(ticket: "t3", heldUntil: d) ==
            "slot ready (ticket t3, held until 09:05): cgate run --ticket t3 --max ... -- <cmd>")
        #expect(CgateMessage.gateOff == "Compute gate off — continue without heavy runs or stop and report")
    }

    @Test func durations() {
        #expect(DurationFormat.parse("90s") == 90)
        #expect(DurationFormat.parse("15m") == 900)
        #expect(DurationFormat.parse("1h30m") == 5400)
        #expect(DurationFormat.parse("20") == 1200)
        #expect(DurationFormat.parse("") == nil)
        #expect(DurationFormat.parse("5x") == nil)
        #expect(DurationFormat.parse("10m5") == nil)
        #expect(DurationFormat.parse("0s") == nil)
        #expect(DurationFormat.format(900) == "15m")
        #expect(DurationFormat.format(5400) == "1h30m")
        #expect(DurationFormat.format(45) == "45s")
        #expect(DurationFormat.format(0) == "0s")
    }

    @Test func defaults() {
        #expect(Defaults.slots == 2)
        #expect(Defaults.defaultMaxRuntime == 900 && Defaults.maxRuntimeCap == 3600)
        #expect(Defaults.ticketHold == 120 && Defaults.walltimeGrace == 60)
        #expect(Defaults.fanWatchdogTimeout == 10 && Defaults.fanHeartbeatInterval == 2)
        #expect(Defaults.fanCurve == FanCurve(lowTemp: 55, highTemp: 85, hysteresis: 3, tick: 2))
    }
}

@Suite struct ContractHelperTests {
    @Test func reattachIsOptionalOnTheWire() throws {
        let line = Data(#"{"v":1,"id":"1","op":"acquire","body":{"sessionId":"s","cwd":"/p","command":"make","pid":1,"autoWrapped":false}}"#.utf8)
        let r = try WireCoding.decode(Request<GateRequest>.self, line: line)
        guard case .acquire(let a) = r.message else { Issue.record("not acquire"); return }
        #expect(a.reattach == nil)
    }

    @Test func commandIsCappedOnSend() {
        let short = "make test"
        #expect(CommandText.capped(short) == short)
        let long = String(repeating: "ä", count: 5000)  // 10'000 UTF-8 bytes
        let c = CommandText.capped(long)
        #expect(c.utf8.count <= Defaults.maxCommandBytes)
        #expect(c.hasSuffix(CommandText.truncationMarker))
        #expect(AcquireRequest(sessionId: "s", cwd: "/", command: long, pid: 1).command == c)
        let exact = String(repeating: "a", count: Defaults.maxCommandBytes)
        #expect(CommandText.capped(exact) == exact)
    }

    @Test func worstCaseStatusFitsInOneLine() throws {
        // Command made of characters that JSON-escape to 6 bytes each.
        let nasty = CommandText.capped(String(repeating: "\u{01}", count: 10_000))
        let lease = Lease(sessionId: String(repeating: "s", count: 64), cwd: String(repeating: "/d", count: 512),
                          command: nasty, pid: 1, pgid: 2, startedAt: t0, maxRuntimeSeconds: 900,
                          autoWrapped: true, messagingSocket: String(repeating: "m", count: 104))
        let status = GateStatus(level: .on, slots: 32, effectiveSlots: 32,
                                leases: Array(repeating: lease, count: 64),
                                tickets: Array(repeating: TicketInfo(id: "t100", position: 1, eta: t0), count: 64),
                                heldSlot: nil, nextSlotETA: t0,
                                pendingNotices: Array(repeating: PendingNotice(sessionId: "s", text: CgateMessage.hardStopNotice), count: 64),
                                settings: GateSettings())
        let bytes = try WireCoding.line(Response(id: "x", GateReply.status(status))).count
        #expect(bytes * 2 < Defaults.maxLineBytes)
    }

    @Test func exitCodes() {
        #expect(CgateExit.spawnFailed == 70)
        #expect(CgateExit.interrupted == 130)
    }
}
