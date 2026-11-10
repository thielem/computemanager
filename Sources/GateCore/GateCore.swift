import Foundation
import Shared

/// Gate state machine + socket server. Placeholder: every op answers `notImplemented`.
/// Owner: package C.
///
/// UI API (frozen): App (B) creates `GateService` with persisted settings/level, subscribes via
/// `onChange`, mutates only via `handle(...)`. `onChange` is invoked after every state change
/// (lease added/removed, ticket change, level/slots/settings change, reaper).
public final class GateService: @unchecked Sendable {
    private let lock = NSLock()
    private var _onChange: (@Sendable (GateStatus) -> Void)?

    public init(settings: GateSettings, level: GateLevel) {}

    public var onChange: (@Sendable (GateStatus) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    public func handle(_ request: GateRequest) async -> Result<GateReply, WireError> {
        .failure(.notImplemented(request.op))
    }

    /// Start serving `gate.sock` (mode 0600).
    public func makeServer(path: String = Paths.gateSocket) -> GateServer {
        GateServer(path: path) { [self] req, _ in await handle(req) }
    }
}
