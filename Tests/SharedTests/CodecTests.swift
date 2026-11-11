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
            .killJob(KillJobRequest(jobId: UUID(), soft: true)),
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

    @Test func killJobSoftBackwardCompatible() throws {
        let id = UUID()
        let old = try JSONDecoder().decode(KillJobRequest.self, from: Data(#"{"jobId":"\#(id.uuidString)"}"#.utf8))
        #expect(old == KillJobRequest(jobId: id) && old.soft == nil)
        let hard = try String(decoding: JSONEncoder().encode(KillJobRequest(jobId: id)), as: UTF8.self)
        #expect(!hard.contains("soft"))  // old peers see the exact old body
        let soft = try JSONDecoder().decode(KillJobRequest.self, from: JSONEncoder().encode(KillJobRequest(jobId: id, soft: true)))
        #expect(soft.soft == true)
    }

    @Test func gateSettingsDecodeWithoutHoldAndGrace() throws {
        let old = #"{"slots":3,"patterns":["make"],"defaultMaxRuntimeSeconds":600,"maxRuntimeCapSeconds":1800}"#
        let s = try JSONDecoder().decode(GateSettings.self, from: Data(old.utf8))
        #expect(s == GateSettings(slots: 3, patterns: ["make"], defaultMaxRuntimeSeconds: 600,
                                  maxRuntimeCapSeconds: 1800))
        #expect(s.ticketHoldSeconds == Defaults.ticketHold && s.walltimeGraceSeconds == Defaults.walltimeGrace)
        let t = try JSONDecoder().decode(TicketInfo.self, from: Data(#"{"id":"t1","position":1}"#.utf8))
        #expect(t.holdSeconds == nil)
        let h = try JSONDecoder().decode(HookCheckRequest.self,
                                         from: Data(#"{"sessionId":"s","toolName":"Bash","command":"ls"}"#.utf8))
        #expect(h.agentId == nil)
        let l = try JSONDecoder().decode(Ticket.self,
                                         from: Data(#"{"id":"t1","sessionId":"s","cwd":"/p","issuedAt":0}"#.utf8))
        #expect(l.agentId == nil)
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

    @Test func setModeCurveIsOptionalAndRoundTrips() throws {
        let old = #"{"v":\#(ProtocolVersion.fand),"id":"1","op":"setMode","body":{"mode":"max"}}"#
        let r = try JSONDecoder().decode(FanRequestEnvelope.self, from: Data(old.utf8))
        #expect(r.message == .setMode(SetModeRequest(mode: .max)))
        let c = FanCurve(lowTemp: 50, highTemp: 80, hysteresis: 2, tick: 2)
        let req = Request(id: "x", FanRequest.setMode(SetModeRequest(mode: .performance, curve: c)))
        #expect(try roundTrip(req) == req)
    }

    @Test func curveClamping() {
        let tick: TimeInterval = 2
        let c = FanCurve(lowTemp: 20, highTemp: 120, hysteresis: 30, tick: 99).clamped(tick: tick)
        #expect(c == FanCurve(lowTemp: 40, highTemp: 95, hysteresis: 10, tick: 2))
        let c2 = FanCurve(lowTemp: 90, highTemp: 60, hysteresis: -1, tick: 2).clamped(tick: tick)
        #expect(c2 == FanCurve(lowTemp: 80, highTemp: 85, hysteresis: 0, tick: 2))
        #expect(Defaults.fanCurve.clamped(tick: tick) == Defaults.fanCurve)
        #expect(FanCurve(lowTemp: .nan, highTemp: 80, hysteresis: 3, tick: 2).clamped(tick: tick) == nil)
        #expect(FanCurve(lowTemp: 50, highTemp: .infinity, hysteresis: 3, tick: 2).clamped(tick: tick) == nil)
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
            "compute busy: ticket t3, position 2, next slot by ~09:05 (latest), then held for you 2 min. Start `cgate wait --ticket t3` in the background now; you'll be notified when it completes. Don't rely on any other message; do other work meanwhile")
        #expect(CgateMessage.busy(TicketInfo(id: "t3", position: 2, eta: d, holdSeconds: 90)).contains("held for you 90 s."))
        #expect(CgateMessage.busy(TicketInfo(id: "t3", position: 1, eta: nil)).contains("next slot time unknown, then held for you 2 min."))
        #expect(CgateMessage.busyWaiting(TicketInfo(id: "t3", position: 2, eta: d))
                .hasPrefix("compute busy: ticket t3, position 2, next slot by ~09:05 (latest); waiting"))
        #expect(CgateMessage.walltimeKilled(max: 900) == "killed: exceeded declared max runtime (15m)")
        #expect(CgateMessage.ticketExpired("t3") == "ticket t3 expired; retry cgate run")
        #expect(CgateMessage.slotReady(ticket: "t3", heldUntil: d, now: d - 120) ==
            "Slot ready for ticket t3 — claim within 2 min with `cgate run --ticket t3 --max <est> -- '<cmd>'`, held until 09:05.")
        #expect(CgateMessage.walltimeNotice(command: "make", max: 600, grace: 60) ==
            "compute gate: max runtime (10m) of `make` exceeded. Stop it now — the process will be killed in 60 s")
        #expect(CgateMessage.jobStopNotice(command: "make").contains("will not be killed automatically"))
        #expect([CgateMessage.human(60), CgateMessage.human(90), CgateMessage.human(120), CgateMessage.human(600)]
                == ["60 s", "90 s", "2 min", "10 min"])
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
