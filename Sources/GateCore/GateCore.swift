import Darwin
import Foundation
import Shared

/// Gate state machine host + socket server. Owner: package C.
///
/// UI API (frozen): App (B) creates `GateService` with persisted settings/level, subscribes via
/// `onChange`, mutates only via `handle(...)`. `onChange` is invoked after every state change
/// (lease added/removed, ticket change, level/slots/settings change, reaper).
///
/// Threading: thread-safe; `handle` may be called from any task/thread. `onChange` is called on a
/// private serial queue (never the main thread), in order, only when the `GateStatus` snapshot
/// actually changed (heartbeats that change nothing do not fire). The UI hops to the main actor
/// itself and runs its own timer for elapsed times.
///
/// Background work (started by `init`): a 1 s tick (walltime, ticket-hold expiry) and a reaper
/// every `Defaults.reaperInterval` (leases whose cgate pid is dead or that sent no heartbeat for
/// `GateMachine.heartbeatTimeout`; a reaped lease's live process group gets SIGTERM, then
/// SIGKILL after `Defaults.killGrace`). Notices are also pushed to the session's Claude Code
/// messaging socket on a background queue.
public final class GateService: @unchecked Sendable {  // all mutable state guarded by `lock`
    private let lock = NSLock()
    private var machine: GateMachine
    private var _onChange: (@Sendable (GateStatus) -> Void)?
    private var lastReap = Date.distantPast
    /// Wall clock vs uptime at the last tick, to detect system sleep.
    private var lastTickWall = Date()
    private var lastTickUptime = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    private let clock: @Sendable () -> Date
    private let isAlive: @Sendable (Int32) -> Bool
    /// `kill(-pgid, sig)`.
    private let signalGroup: @Sendable (Int32, Int32) -> Int32
    private let killGrace: TimeInterval
    private let pusher: NoticePusher
    private let pollWindow: TimeInterval
    private let pollStep: TimeInterval
    private let notifyQueue = DispatchQueue(label: "computemanager.gate.onChange")
    private let pushQueue = DispatchQueue(label: "computemanager.gate.push")

    public convenience init(settings: GateSettings, level: GateLevel) {
        self.init(settings: settings, level: level, clock: { Date() }, isAlive: Self.pidAlive,
                  pusher: .live, pollWindow: Defaults.waitTicketPollWindow, autoTick: true)
    }

    /// Test/DI initializer.
    init(settings: GateSettings, level: GateLevel, clock: @escaping @Sendable () -> Date,
         isAlive: @escaping @Sendable (Int32) -> Bool, pusher: NoticePusher,
         pollWindow: TimeInterval, pollStep: TimeInterval = 0.2, autoTick: Bool,
         signalGroup: @escaping @Sendable (Int32, Int32) -> Int32 = { kill(-$0, $1) },
         killGrace: TimeInterval = Defaults.killGrace) {
        machine = GateMachine(settings: settings, level: level)
        self.clock = clock
        self.isAlive = isAlive
        self.signalGroup = signalGroup
        self.killGrace = killGrace
        self.pusher = pusher
        self.pollWindow = pollWindow
        self.pollStep = pollStep
        if autoTick { startTimer() }
    }

    deinit { timer?.cancel() }

    public var onChange: (@Sendable (GateStatus) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    public func handle(_ request: GateRequest) async -> Result<GateReply, WireError> {
        switch request {
        case .acquire(let r):
            return .success(.acquire(mutate { $0.acquire(r, now: $1) }))
        case .release(let r):
            mutate { $0.release(r.jobId, now: $1) }
            return .success(.release)
        case .heartbeat(let r):
            return .success(.heartbeat(mutate { $0.heartbeat(r, now: $1) }))
        case .hookCheck(let r):
            return .success(.hookCheck(mutate { $0.hookCheck(r, now: $1) }))
        case .waitTicket(let r):
            return .success(.waitTicket(await waitTicket(r.ticket)))
        case .status:
            return .success(.status(mutate { m, now in m.advance(now: now); return m.snapshot(now: now) }))
        case .setGate(let r):
            return .success(.setGate(mutate { m, now in
                m.setGate(r.level, slots: r.slots, now: now)
                return m.snapshot(now: now)
            }))
        case .meeting:
            return .success(.meeting(mutate { m, now in
                m.meeting(now: now)
                return m.snapshot(now: now)
            }))
        case .killJob(let r):
            let s: GateStatus? = mutate { m, now in m.killJob(r.jobId, now: now) ? m.snapshot(now: now) : nil }
            guard let s else { return .failure(WireError(.invalidState, "unknown job \(r.jobId)")) }
            return .success(.killJob(s))
        case .setSettings(let g):
            return .success(.setSettings(mutate { m, now in
                m.setSettings(g, now: now)
                return m.snapshot(now: now)
            }))
        }
    }

    /// Start serving `gate.sock` (mode 0600).
    public func makeServer(path: String = Paths.gateSocket) -> GateServer {
        GateServer(path: path) { [self] req, _ in await handle(req) }
    }

    // MARK: Internals

    /// Run one state transition under the lock; fire `onChange` if the snapshot changed and
    /// deliver queued pushes outside the lock.
    @discardableResult
    func mutate<T>(_ body: (inout GateMachine, Date) -> T) -> T {
        let (result, pushes) = lock.withLock {
            let now = clock()
            let before = machine.snapshot(now: now)
            let result = body(&machine, now)
            let after = machine.snapshot(now: now)
            if before != after, let cb = _onChange { notifyQueue.async { cb(after) } }
            let pushes = machine.outbox
            machine.outbox = []
            return (result, pushes)
        }
        deliver(pushes)
        return result
    }

    private func deliver(_ pushes: [Push]) {
        guard !pushes.isEmpty else { return }
        let pusher = pusher
        pushQueue.async {
            for p in pushes {
                guard let socket = p.socket ?? pusher.resolveSocket(p.sessionId) else { continue }
                pusher.push(socket, p.text)
            }
        }
    }

    /// Long-poll: until the ticket is held (ready) or gone (expired), at most `pollWindow`.
    func waitTicket(_ id: String) async -> WaitTicketResult {
        mutate { m, _ in m.waiters[id, default: 0] += 1 }
        defer {
            mutate { m, now in m.endWait(id, now: now) }
        }
        let start = Date()
        while true {
            let r = mutate { $0.waitStatus(id, now: $1) }
            guard case .pending = r, Date().timeIntervalSince(start) < pollWindow else { return r }
            try? await Task.sleep(nanoseconds: UInt64(pollStep * 1e9))
        }
    }

    /// Walltime / hold expiry; reaper when due.
    func tick() {
        let wall = Date(), up = ProcessInfo.processInfo.systemUptime
        let slept = wall.timeIntervalSince(lastTickWall) - (up - lastTickUptime) > 5
        (lastTickWall, lastTickUptime) = (wall, up)  // only touched on the tick queue
        mutate { m, now in
            if slept { m.touchAll(now: now) }  // nobody could heartbeat while asleep
            m.advance(now: now)
        }
        let due: [Int32]? = lock.withLock {
            let now = clock()
            guard now.timeIntervalSince(lastReap) >= Defaults.reaperInterval else { return nil }
            lastReap = now
            return machine.leases.map(\.pid)
        }
        guard let pids = due else { return }
        let dead = Set(pids.filter { !isAlive($0) })
        let gone = mutate { $0.reap(dead: dead, now: $1) }
        killGroups(gone.compactMap(\.pgid))
    }

    /// Orphaned process groups of reaped leases: SIGTERM, SIGKILL after `killGrace` if alive.
    private func killGroups(_ pgids: [Int32]) {
        let signalGroup = signalGroup
        for g in pgids where g > 1 && g != getpgrp() && signalGroup(g, 0) == 0 {
            _ = signalGroup(g, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if signalGroup(g, 0) == 0 { _ = signalGroup(g, SIGKILL) }
            }
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "computemanager.gate.tick"))
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    static let pidAlive: @Sendable (Int32) -> Bool = { pid in
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
