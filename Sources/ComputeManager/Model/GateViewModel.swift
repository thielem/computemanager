import Foundation
import Observation
import Shared

/// UI state of the gate. Mutates only through `GateBackend.handle`.
@MainActor @Observable
final class GateViewModel {
    private(set) var status: GateStatus
    /// Gate toggled off while jobs run: the UI shows No more / Soft / Hard.
    private(set) var offChoicePending = false
    private(set) var lastError: String?

    @ObservationIgnored private let backend: GateBackend
    @ObservationIgnored var onPersist: ((GateStore.Snapshot) -> Void)?

    init(backend: GateBackend, initial: GateStatus) {
        self.backend = backend
        self.status = initial
        backend.onChange = { [weak self] s in
            Task { @MainActor in self?.apply(s) }
        }
    }

    var isOn: Bool { status.level == .on }
    var runningJobs: [Lease] { status.leases.filter { $0.state != .done } }
    var queuedCount: Int { status.tickets.count }
    /// Stronger off levels still available (No more → Soft → Hard), only while jobs run.
    var escalations: [GateLevel] {
        guard status.level.isOff, !runningJobs.isEmpty else { return [] }
        let order: [GateLevel] = [.noMore, .softStop, .hardStop]
        guard let i = order.firstIndex(of: status.level) else { return [] }
        return Array(order[(i + 1)...])
    }

    func refresh() async { await send(.status) }

    func setOn(_ on: Bool) async {
        if on {
            offChoicePending = false
            await send(.setGate(SetGateRequest(level: .on)))
        } else if runningJobs.isEmpty {
            await send(.setGate(SetGateRequest(level: .noMore)))
        } else {
            offChoicePending = true
        }
    }

    func chooseOff(_ level: GateLevel) async {
        offChoicePending = false
        await send(.setGate(SetGateRequest(level: level)))
    }

    func cancelOffChoice() { offChoicePending = false }

    func setSlots(_ n: Int) async {
        await send(.setGate(SetGateRequest(level: status.level, slots: max(1, n))))
    }

    func kill(_ jobId: UUID) async { await send(.killJob(KillJobRequest(jobId: jobId))) }

    func meeting() async {
        offChoicePending = false
        await send(.meeting)
    }

    func updateSettings(_ s: GateSettings) async { await send(.setSettings(s)) }

    func apply(_ s: GateStatus) {
        let changed = s.level != status.level || s.settings != status.settings
        status = s
        if changed { onPersist?(GateStore.Snapshot(settings: s.settings, level: s.level)) }
    }

    private func send(_ req: GateRequest) async {
        switch await backend.handle(req) {
        case .success(let reply):
            lastError = nil
            if let s = reply.gateStatus { apply(s) }
        case .failure(let e):
            lastError = e.message.isEmpty ? e.code.rawValue : e.message
        }
    }
}
