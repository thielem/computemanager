import Foundation
import Shared

/// fand's fan state machine. All inputs carry `now` (injected clock) so tests drive time.
/// `now` is the watchdog clock (monotonic in the daemon, see `Monotonic`); `wallClock` only
/// stamps `FanStatus.lastHeartbeat` for display.
///
/// Safety (FAN-4..7):
/// - `start` and `shutdown` force Auto.
/// - A control connection (one that sent `setMode`/`heartbeat`) disconnecting → Auto.
/// - Watchdog: in a manual mode, no `setMode`/`heartbeat` from the controlling connection (the one
///   that last sent `setMode`) for `watchdogTimeout` → Auto (checked on every `tick`, so it fires
///   within timeout + tick). Heartbeats from other connections don't count.
/// - After `shutdown` every input is a no-op (fans stay Auto until exit).
/// - `wake` re-applies the current mode (curve state reset, all keys re-written).
/// Manual modes are also re-asserted on every tick if the SMC dropped them.
final class FanController: @unchecked Sendable {  // all state guarded by `lock`
    let hw: FanHardware
    /// Tick interval, fixed at start (not changeable over IPC).
    let tick: TimeInterval
    let watchdogTimeout: TimeInterval
    private let thermal: @Sendable () -> ThermalState
    private let log: @Sendable (String) -> Void
    private let wallClock: @Sendable () -> Date

    private let lock = NSLock()
    private var mode: FanMode = .auto
    private var _curve: FanCurve
    private var lastHeartbeat: Date?       // watchdog clock
    private var lastHeartbeatWall: Date?   // display only
    private var controllingConnection: UInt64?
    private var stopped = false
    private var controlConnections: Set<UInt64> = []
    private var curveState: CurveState
    private var last: FanStatus
    /// Called (outside the lock) after every state refresh, for `subscribe` pushes.
    private let onChange: @Sendable (FanStatus) -> Void

    init(hw: FanHardware, curve: FanCurve = Defaults.fanCurve,
         watchdogTimeout: TimeInterval = Defaults.fanWatchdogTimeout,
         thermal: @escaping @Sendable () -> ThermalState = { ThermalState(ProcessInfo.processInfo.thermalState) },
         log: @escaping @Sendable (String) -> Void = { _ in },
         wallClock: @escaping @Sendable () -> Date = { Date() },
         onChange: @escaping @Sendable (FanStatus) -> Void = { _ in }) {
        self.hw = hw
        self.tick = curve.tick
        self._curve = curve
        self.watchdogTimeout = watchdogTimeout
        self.thermal = thermal
        self.log = log
        self.wallClock = wallClock
        self.onChange = onChange
        self.curveState = CurveState(curve: curve)
        self.last = FanStatus(mode: .auto, fans: [], temps: Temperatures(), thermalState: .nominal,
                              lastHeartbeat: nil, curve: curve)
    }

    // MARK: Inputs

    /// Daemon start: force Auto (FAN-6).
    func start(now: Date) {
        run { revertLocked("start"); return last }
    }

    /// Daemon exit (SIGTERM/SIGINT): force Auto (FAN-6).
    func shutdown() {
        run { revertLocked("shutdown"); stopped = true; return last }
    }

    /// `curve` must already be validated (`FanCurve.clamped`); nil keeps the current curve.
    /// A new curve takes effect immediately (performance) and on every following tick.
    @discardableResult
    func setMode(_ m: FanMode, curve newCurve: FanCurve? = nil, connection: UInt64?, now: Date) -> FanStatus {
        run {
            guard !stopped else { return last }
            if let connection { controlConnections.insert(connection) }
            controllingConnection = connection
            beatLocked(now)
            if let c = newCurve, c != _curve {
                log("curve \(Int(c.lowTemp))-\(Int(c.highTemp)) h\(Int(c.hysteresis))")
                _curve = c
                curveState = CurveState(curve: c)
            }
            if m != mode {
                log("setMode \(mode.rawValue) -> \(m.rawValue)")
                mode = m
                curveState.reset()
            }
            if m == .auto { revertLocked(nil); return last }  // always re-write: idempotent, safe
            return applyLocked()
        }
    }

    func heartbeat(connection: UInt64?, now: Date) {
        run(notify: false) {
            guard !stopped else { return last }
            if let connection { controlConnections.insert(connection) }
            if connection == controllingConnection { beatLocked(now) }
            return last
        }
    }

    /// A connection closed. Control connection → Auto (FAN-4: app crashed or quit).
    func disconnected(connection: UInt64) {
        run {
            guard !stopped, controlConnections.remove(connection) != nil else { return last }
            if mode != .auto { revertLocked("control connection closed") }
            return last
        }
    }

    /// Periodic tick (`curve.tick`): watchdog, then apply the current mode.
    @discardableResult
    func tick(now: Date) -> FanStatus {
        run {
            guard !stopped else { return last }
            if mode != .auto, now.timeIntervalSince(lastHeartbeat ?? .distantPast) > watchdogTimeout {
                revertLocked("watchdog: no heartbeat for \(Int(watchdogTimeout)) s")
                return last
            }
            return mode == .auto ? refreshLocked() : applyLocked()
        }
    }

    /// System woke: SMC may have reset fan keys → re-apply (FAN-7).
    func wake(now: Date) {
        _ = run {
            guard !stopped else { return last }
            log("wake: re-applying \(mode.rawValue)")
            curveState.reset()
            if mode == .auto { revertLocked(nil) } else { return applyLocked() }
            return last
        }
    }

    /// Fresh status (reads the SMC).
    func status() -> FanStatus { run(notify: false) { refreshLocked() } }

    var curve: FanCurve { lock.withLock { _curve } }

    var currentMode: FanMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    // MARK: Internals (lock held)

    @discardableResult
    private func run(notify: Bool = true, _ body: () -> FanStatus) -> FanStatus {
        lock.lock()
        let s = body()
        lock.unlock()
        if notify { onChange(s) }
        return s
    }

    private func beatLocked(_ now: Date) {
        lastHeartbeat = now
        lastHeartbeatWall = wallClock()
        last.lastHeartbeat = lastHeartbeatWall
    }

    /// Force Auto, then refresh `last`. `reason` nil = don't log.
    private func revertLocked(_ reason: String?) {
        if let reason { log("revert to auto (\(reason))") }
        mode = .auto
        curveState.reset()
        for e in hw.setAuto() { log("revert error: \(e)") }
        _ = refreshLocked()
    }

    @discardableResult
    private func refreshLocked() -> FanStatus {
        last = FanStatus(mode: mode, fans: hw.readFans(), temps: hw.readTemps(), thermalState: thermal(),
                         lastHeartbeat: lastHeartbeatWall, curve: _curve)
        return last
    }

    /// Apply the manual mode (max / performance) and refresh.
    private func applyLocked() -> FanStatus {
        let before = refreshLocked()
        let targets: [Int: Double]
        switch mode {
        case .auto:
            return before
        case .max:
            targets = Dictionary(uniqueKeysWithValues: hw.fans.map { ($0.id, $0.maxRPM) })
        case .performance:
            let frac: Double
            if before.thermalState >= .serious {
                frac = 1  // FAN-3
            } else if let t = before.temps.pcoreMax {
                frac = curveState.fraction(curveState.update(t))
            } else {
                frac = 1  // no plausible P-core sensor: fail safe to max cooling
            }
            targets = Dictionary(uniqueKeysWithValues: hw.fans.map {
                ($0.id, CurveState.rpm(fraction: frac, minRPM: $0.minRPM, maxRPM: $0.maxRPM))
            })
        }
        let errors = hw.setManual(targets, current: before.fans)
        for e in errors { log("apply error: \(e)") }
        return refreshLocked()
    }
}
