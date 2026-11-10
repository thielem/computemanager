import Foundation
import Shared

/// Gate state machine + socket server. Placeholder: every op answers `notImplemented`.
/// Owner: package C.
public final class GateService: Sendable {
    public init() {}

    public func handle(_ request: GateRequest) async -> Result<GateReply, WireError> {
        .failure(.notImplemented(request.op))
    }

    /// Start serving `gate.sock` (mode 0600).
    public func makeServer(path: String = Paths.gateSocket) -> GateServer {
        GateServer(path: path) { [self] req, _ in await handle(req) }
    }
}
