import Foundation
import Shared
@testable import ComputeManager

/// In-memory gate: applies setGate/meeting/killJob/setSettings to a status and records requests.
final class FakeGate: GateBackend, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var _onChange: (@Sendable (GateStatus) -> Void)?
    private(set) var status: GateStatus
    private(set) var requests: [GateRequest] = []

    init(leases: [Lease] = [], level: GateLevel = .on) {
        status = .initial(settings: GateSettings(), level: level)
        status.leases = leases
    }

    var onChange: (@Sendable (GateStatus) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    func handle(_ request: GateRequest) async -> Result<GateReply, WireError> {
        lock.withLock {
            requests.append(request)
            switch request {
            case .status: return .success(.status(status))
            case .setGate(let r):
                status.level = r.level
                if let n = r.slots { status.slots = n; status.settings.slots = n }
                return .success(.setGate(status))
            case .meeting:
                status.level = .noMore
                return .success(.meeting(status))
            case .killJob(let k):
                guard let i = status.leases.firstIndex(where: { $0.jobId == k.jobId }) else {
                    return .failure(WireError(.invalidState, "unknown job"))
                }
                status.leases[i].state = .killing
                return .success(.killJob(status))
            case .setSettings(let s):
                status.settings = s
                return .success(.setSettings(status))
            default: return .failure(.notImplemented(request.op))
            }
        }
    }
}

final class FakeFanLink: FanControlling, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var _onStatus: (@Sendable (FanStatus?) -> Void)?
    private(set) var modes: [FanMode] = []
    var onStatus: (@Sendable (FanStatus?) -> Void)? {
        get { lock.withLock { _onStatus } }
        set { lock.withLock { _onStatus = newValue } }
    }
    func start() {}
    func setMode(_ mode: FanMode) { lock.withLock { modes.append(mode) } }
    func shutdown() { setMode(.auto) }
}

func lease(_ project: String = "proj") -> Lease {
    Lease(sessionId: "abcdef123", cwd: "/tmp/\(project)", command: "swift test", pid: 1, pgid: 2,
          startedAt: Date(timeIntervalSince1970: 0), maxRuntimeSeconds: 900, autoWrapped: true)
}
