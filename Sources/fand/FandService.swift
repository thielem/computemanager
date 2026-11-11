import Darwin
import Foundation
import Shared
import SystemConfiguration

/// Fan-out of status snapshots to `subscribe` streams.
final class StatusHub: @unchecked Sendable {  // `subs` guarded by `lock`
    private let lock = NSLock()
    private var subs: [UUID: AsyncStream<FanStatus>.Continuation] = [:]

    func subscribe() -> (UUID, AsyncStream<FanStatus>) {
        let (stream, cont) = AsyncStream.makeStream(of: FanStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.lock()
        subs[id] = cont
        lock.unlock()
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        lock.lock()
        let c = subs.removeValue(forKey: id)
        lock.unlock()
        c?.finish()
    }

    func publish(_ s: FanStatus) {
        lock.lock()
        let cs = Array(subs.values)
        lock.unlock()
        for c in cs { c.yield(s) }
    }

    func finishAll() {
        lock.lock()
        let cs = Array(subs.values)
        subs.removeAll()
        lock.unlock()
        for c in cs { c.finish() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return subs.count
    }
}

/// FAN-9: allow root and the console user only.
enum PeerAuth {
    /// UID of the user logged in at the console; nil at the login window.
    static func consoleUID() -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", !name.isEmpty else { return nil }
        return uid
    }

    static func isAllowed(peerUID: uid_t?, consoleUID: uid_t?) -> Bool {
        guard let peerUID else { return false }
        return peerUID == 0 || (consoleUID != nil && peerUID == consoleUID)
    }
}

/// Request handling for fand.sock: wires `FanController` + `StatusHub` to `FanServer`.
/// Ticks are pushed to subscribers via the controller's `onChange` (every tick = 2 s, plus
/// setMode / revert / wake).
final class FandService: Sendable {
    let controller: FanController
    let hub: StatusHub
    let server: FanServer

    init(controller: FanController, hub: StatusHub, path: String,
         authorize: @escaping FanServer.Authorizer = { PeerAuth.isAllowed(peerUID: $0?.uid, consoleUID: PeerAuth.consoleUID()) }) {
        self.controller = controller
        self.hub = hub
        self.server = FanServer(
            path: path, authorize: authorize,
            onDisconnect: { [controller] conn, _ in controller.disconnected(connection: conn.raw) },
            handler: { [controller, hub] req, ctx in
                await Self.handle(req, ctx, controller: controller, hub: hub)
            })
    }

    /// The socket is 0666; access control is the peer-UID check (PLAN §4 fand.sock).
    func start() throws { try server.start(mode: 0o666) }

    func stop() {
        hub.finishAll()
        server.stop()
    }

    static func handle(_ req: FanRequest, _ ctx: RequestContext<FanReply>,
                       controller: FanController, hub: StatusHub) async -> Result<FanReply, WireError> {
        switch req {
        case .status:
            return .success(.status(controller.status()))
        case .setMode(let r):
            var curve: FanCurve?
            if let c = r.curve {
                guard let v = c.clamped(tick: controller.tick) else {
                    return .failure(WireError(.badRequest, "invalid curve"))
                }
                curve = v
            }
            return .success(.setMode(controller.setMode(r.mode, curve: curve, connection: ctx.connectionId.raw,
                                                        now: Monotonic.now())))
        case .heartbeat:
            controller.heartbeat(connection: ctx.connectionId.raw, now: Monotonic.now())
            return .success(.heartbeat)
        case .subscribe:
            let (id, stream) = hub.subscribe()
            defer { hub.unsubscribe(id) }
            do {
                try ctx.push(.subscribe(controller.status()))
                for await s in stream { try ctx.push(.subscribe(s)) }
            } catch {
                // Client went away / stopped reading; the reply below fails too and ends the connection.
            }
            return .failure(WireError(.invalidState, "subscription ended"))
        }
    }
}
