import Foundation
import Shared

/// What the fan view model needs from the fand connection (fake in tests).
protocol FanControlling: AnyObject, Sendable {
    /// Called with every fresh status; nil when fand is unreachable. Any thread.
    var onStatus: (@Sendable (FanStatus?) -> Void)? { get set }
    func start()
    func setMode(_ mode: FanMode)
    /// Blocking: set Auto and disconnect (app quit).
    func shutdown()
}

/// fand client: one `subscribe` connection on its own thread, one control connection
/// (`setMode`/`heartbeat`) on a serial queue. Heartbeat every `heartbeatInterval`; both
/// connections reconnect with exponential backoff; the control connection re-sends the
/// current mode right after (re)connecting, because fand reverts to Auto when it drops.
final class FanLink: FanControlling, @unchecked Sendable {
    // Control state is confined to `queue`; `subscriber`/`stopped`/`_onStatus` use `lock`.
    let path: String
    private let heartbeatInterval: TimeInterval
    private let minBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private let clientTimeout: TimeInterval

    private let queue = DispatchQueue(label: "computemanager.fan.control")
    private var control: FanClient?
    private var desired: FanMode = .auto
    private var controlBackoff: TimeInterval
    private var nextAttempt = Date.distantPast
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var subscriber: FanClient?
    private var stopped = false
    private var _onStatus: (@Sendable (FanStatus?) -> Void)?

    var onStatus: (@Sendable (FanStatus?) -> Void)? {
        get { lock.withLock { _onStatus } }
        set { lock.withLock { _onStatus = newValue } }
    }

    init(path: String = Paths.fandSocket, heartbeatInterval: TimeInterval = Defaults.fanHeartbeatInterval,
         minBackoff: TimeInterval = 0.5, maxBackoff: TimeInterval = 8, clientTimeout: TimeInterval = 2) {
        self.path = path
        self.heartbeatInterval = heartbeatInterval
        self.minBackoff = minBackoff
        self.maxBackoff = maxBackoff
        self.clientTimeout = clientTimeout
        self.controlBackoff = minBackoff
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: heartbeatInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        queue.sync { timer = t }
        t.resume()
        let th = Thread { [weak self] in self?.subscribeLoop() }
        th.name = "computemanager.fan.subscribe"
        th.start()
    }

    func setMode(_ mode: FanMode) {
        queue.async { [self] in
            desired = mode
            if control == nil {
                _ = connectControl()
            } else {
                callControl(.setMode(SetModeRequest(mode: mode)))
            }
        }
    }

    func shutdown() {
        lock.withLock {
            stopped = true
            subscriber?.close()
        }
        queue.sync {
            timer?.cancel()
            timer = nil
            desired = .auto
            nextAttempt = .distantPast
            if control == nil {
                _ = connectControl()  // connecting sends setMode(auto)
            } else {
                callControl(.setMode(SetModeRequest(mode: .auto)))
            }
            control?.close()
            control = nil
        }
    }

    // MARK: Control (on `queue`)

    private func tick() {
        guard control != nil else { _ = connectControl(); return }
        callControl(.heartbeat)
    }

    /// Connect if the backoff allows, then send the current mode. Returns success.
    private func connectControl() -> Bool {
        guard Date() >= nextAttempt else { return false }
        do {
            let c = try FanClient(path: path, timeout: clientTimeout)
            let reply = try c.call(.setMode(SetModeRequest(mode: desired)))
            control = c
            controlBackoff = minBackoff
            if case .setMode(let s) = reply { onStatus?(s) }
            return true
        } catch {
            nextAttempt = Date().addingTimeInterval(controlBackoff)
            controlBackoff = min(controlBackoff * 2, maxBackoff)
            return false
        }
    }

    private func callControl(_ req: FanRequest) {
        guard let c = control else { return }
        do {
            if case .setMode(let s) = try c.call(req) { onStatus?(s) }
        } catch {
            c.close()
            control = nil
            nextAttempt = .distantPast  // first reconnect right away, then back off
        }
    }

    // MARK: Subscribe (own thread)

    private func subscribeLoop() {
        var backoff = minBackoff
        while !lock.withLock({ stopped }) {
            do {
                let c = try FanClient(path: path, timeout: max(clientTimeout, Defaults.fanSubscribeInterval * 2.5))
                let keep = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    subscriber = c
                    return true
                }
                guard keep else { c.close(); return }
                try c.send(.subscribe)
                while true {
                    let r = try c.next()
                    if case .subscribe(let s) = try r.result.get() {
                        backoff = minBackoff
                        onStatus?(s)
                    }
                }
            } catch {
                lock.withLock {
                    subscriber?.close()
                    subscriber = nil
                }
                if lock.withLock({ stopped }) { return }
                onStatus?(nil)
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }
}
