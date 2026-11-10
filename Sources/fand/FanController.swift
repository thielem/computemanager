import Foundation
import Shared

/// fand's fan state machine. All inputs carry `now` (injected clock) so tests drive time.
///
/// Safety (FAN-4..7):
/// - `start` and `shutdown` force Auto.
/// - A control connection (one that sent `setMode`/`heartbeat`) disconnecting → Auto.
/// - Watchdog: in a manual mode, no `heartbeat`/`setMode` for `watchdogTimeout` → Auto
///   (checked on every `tick`, so it fires within timeout + tick).
/// - `wake` re-applies the current mode (curve state reset, all keys re-written).
/// Manual modes are also re-asserted on every tick if the SMC dropped them.
final class FanController: @unchecked Sendable {  // all state guarded by `lock`
    let hw: FanHardware
    let curve: FanCurve
    let watchdogTimeout: TimeInterval
    private let thermal: @Sendable () -> ThermalState
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var mode: FanMode = .auto
    private var lastHeartbeat: Date?
    private var controlConnections: Set<UInt64> = []
    private var curveState: CurveState
    private var last: FanStatus
    /// Called (outside the lock) after every state refresh, for `subscribe` pushes.
    private let onChange: @Sendable (FanStatus) -> Void

    init(hw: FanHardware, curve: FanCurve = Defaults.fanCurve,
         watchdogTimeout: TimeInterval = Defaults.fanWatchdogTimeout,
         thermal: @escaping @Sendable () -> ThermalState = { ThermalState(ProcessInfo.processInfo.thermalState) },
         log: @escaping @Sendable (String) -> Void = { _ in },
         onChange: @escaping @Sendable (FanStatus) -> Void = { _ in }) {
        self.hw = hw
        self.curve = curve
        self.watchdogTimeout = watchdogTimeout
        self.thermal = thermal
        self.log = log
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
        run { revertLocked("shutdown"); return last }
    }

    @discardableResult
    func setMode(_ m: FanMode, connection: UInt64?, now: Date) -> FanStatus {
        run {
            if let connection { controlConnections.insert(connection) }
            lastHeartbeat = now
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
            if let connection { controlConnections.insert(connection) }
            lastHeartbeat = now
            last.lastHeartbeat = now
            return last
        }
    }

    /// A connection closed. Control connection → Auto (FAN-4: app crashed or quit).
    func disconnected(connection: UInt64) {
        run {
            guard controlConnections.remove(connection) != nil else { return last }
            if mode != .auto { revertLocked("control connection closed") }
            return last
        }
    }

    /// Periodic tick (`curve.tick`): watchdog, then apply the current mode.
    @discardableResult
    func tick(now: Date) -> FanStatus {
        run {
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
            log("wake: re-applying \(mode.rawValue)")
            curveState.reset()
            if mode == .auto { revertLocked(nil) } else { return applyLocked() }
            return last
        }
    }

    /// Fresh status (reads the SMC).
    func status() -> FanStatus { run(notify: false) { refreshLocked() } }

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
                         lastHeartbeat: lastHeartbeat, curve: curve)
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
