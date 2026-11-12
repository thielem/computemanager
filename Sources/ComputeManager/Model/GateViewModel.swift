import Foundation
import Observation
import Shared

/// UI state of the gate. Mutates only through `GateBackend.handle`.
@MainActor @Observable
final class GateViewModel {
    private(set) var status: GateStatus
    private(set) var lastError: String?

    @ObservationIgnored private let backend: GateBackend
    @ObservationIgnored var onPersist: ((GateStore.Snapshot) -> Void)?
    @ObservationIgnored private let seq = Sequencer()
    @ObservationIgnored private var applied: UInt64 = 0

    init(backend: GateBackend, initial: GateStatus) {
        self.backend = backend
        self.status = initial
        let seq = seq
        backend.onChange = { [weak self] s in
            let n = seq.next()
            Task { @MainActor in self?.apply(s, seq: n) }
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
        await send(.setGate(SetGateRequest(level: on ? .on : .noMore)))
    }

    func chooseOff(_ level: GateLevel) async {
        await send(.setGate(SetGateRequest(level: level)))
    }

    func setSlots(_ n: Int) async {
        await send(.setGate(SetGateRequest(level: status.level, slots: max(0, n))))
    }

    /// Per-job ✕: a running job is asked to stop (soft); a stop-requested one is killed.
    func stop(_ jobId: UUID) async {
        let soft = status.leases.first { $0.jobId == jobId }?.state == .running
        await send(.killJob(KillJobRequest(jobId: jobId, soft: soft ? true : nil)))
    }

    func meeting() async {
        await send(.meeting)
    }

    func updateSettings(_ s: GateSettings) async { await send(.setSettings(s)) }

    func apply(_ s: GateStatus) { apply(s, seq: seq.next()) }

    /// Applies `s` unless a snapshot with a higher sequence number was applied already.
    func apply(_ s: GateStatus, seq n: UInt64) {
        guard n > applied else { return }
        applied = n
        let changed = s.level != status.level || s.settings != status.settings
        status = s
        if changed { onPersist?(GateStore.Snapshot(settings: s.settings, level: s.level)) }
    }

    private func send(_ req: GateRequest) async {
        // Stamped before the call: an onChange fired during/after it is at least as new.
        let n = seq.next()
        switch await backend.handle(req) {
        case .success(let reply):
            lastError = nil
            if let s = reply.gateStatus { apply(s, seq: n) }
        case .failure(let e):
            lastError = e.message.isEmpty ? e.code.rawValue : e.message
        }
    }
}
