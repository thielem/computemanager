import Foundation
import Shared

/// In-memory gate with sample jobs, for previews and `COMPUTEMANAGER_DEMO=1` screenshots.
final class DemoGate: GateBackend, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var _onChange: (@Sendable (GateStatus) -> Void)?
    private var status: GateStatus

    init(now: Date = Date()) {
        status = .initial(settings: GateSettings(), level: .on)
        status.leases = [
            Lease(sessionId: "8f3a1c92-77e0", cwd: "/Users/me/code/computemanager",
                  command: "scripts/check.sh", pid: 1, pgid: 1,
                  startedAt: now.addingTimeInterval(-192), maxRuntimeSeconds: 900, autoWrapped: true),
            Lease(sessionId: "c41d07be-0a2f", cwd: "/Users/me/code/webshop",
                  command: "pnpm playwright test --project=chromium --workers=4 tests/e2e/checkout.spec.ts",
                  pid: 2, pgid: 2, startedAt: now.addingTimeInterval(-611), maxRuntimeSeconds: 1200,
                  autoWrapped: true),
        ]
        status.tickets = [TicketInfo(id: "t3", position: 1, eta: now.addingTimeInterval(300))]
    }

    var onChange: (@Sendable (GateStatus) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    func handle(_ request: GateRequest) async -> Result<GateReply, WireError> {
        lock.withLock {
            switch request {
            case .status: return .success(.status(status))
            case .setGate(let r):
                status.level = r.level
                if let n = r.slots { status.slots = n; status.settings.slots = n }
                status.effectiveSlots = r.level.isOff ? 0 : status.slots
                return .success(.setGate(status))
            case .meeting:
                status.level = .noMore
                status.effectiveSlots = 0
                return .success(.meeting(status))
            case .killJob(let k):
                status.leases.removeAll { $0.jobId == k.jobId }
                return .success(.killJob(status))
            case .setSettings(let s):
                status.settings = s
                return .success(.setSettings(status))
            default: return .failure(.notImplemented(request.op))
            }
        }
    }
}
