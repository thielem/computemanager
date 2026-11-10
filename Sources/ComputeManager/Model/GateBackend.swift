import GateCore
import Shared

/// The slice of `GateService` the UI uses. Lets previews/tests swap in a fake.
protocol GateBackend: AnyObject, Sendable {
    var onChange: (@Sendable (GateStatus) -> Void)? { get set }
    func handle(_ request: GateRequest) async -> Result<GateReply, WireError>
}

extension GateService: GateBackend {}

extension GateReply {
    /// The `GateStatus` carried by UI-facing replies.
    var gateStatus: GateStatus? {
        switch self {
        case .status(let s), .setGate(let s), .meeting(let s), .killJob(let s), .setSettings(let s): s
        default: nil
        }
    }
}

extension GateStatus {
    /// Local stand-in until the service answers `status`.
    static func initial(settings: GateSettings, level: GateLevel) -> GateStatus {
        GateStatus(level: level, slots: settings.slots,
                   effectiveSlots: level.isOff ? 0 : settings.slots, leases: [], tickets: [],
                   heldSlot: nil, nextSlotETA: nil, pendingNotices: [], settings: settings)
    }
}
