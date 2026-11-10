import Foundation
import Observation
import Shared

@MainActor @Observable
final class FanViewModel {
    /// Mode the user selected (what the app keeps asking fand for).
    private(set) var mode: FanMode = .auto
    private(set) var status: FanStatus?
    /// fand socket file exists (installed) even if not answering right now.
    private(set) var installed = true

    @ObservationIgnored private let link: FanControlling
    @ObservationIgnored private let socketPath: String?
    @ObservationIgnored private let seq = Sequencer()
    @ObservationIgnored private var applied: UInt64 = 0
    /// Held while a non-Auto mode is wanted, so App Nap cannot stall heartbeats (fand's
    /// watchdog would revert to Auto).
    @ObservationIgnored private(set) var activity: NSObjectProtocol?

    init(link: FanControlling, socketPath: String? = nil) {
        self.link = link
        self.socketPath = socketPath
        let seq = seq
        link.onStatus = { [weak self] s in
            let n = seq.next()
            Task { @MainActor in self?.apply(s, seq: n) }
        }
    }

    var reachable: Bool { status != nil }
    /// Hottest CPU temperature (P- or E-cores), °C.
    var hottestCPU: Double? {
        [status?.temps.pcoreMax, status?.temps.ecoreMax].compactMap { $0 }.max()
    }

    func start() { link.start() }

    func select(_ m: FanMode) {
        mode = m
        link.setMode(m)
        if m == .auto {
            endActivity()
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Fan mode heartbeat")
        }
    }

    func shutdown() {
        link.shutdown()
        endActivity()
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    func apply(_ s: FanStatus?) { apply(s, seq: seq.next()) }

    /// Applies `s` unless a newer status was applied already.
    func apply(_ s: FanStatus?, seq n: UInt64) {
        guard n > applied else { return }
        applied = n
        status = s
        if s == nil, let p = socketPath { installed = FileManager.default.fileExists(atPath: p) }
        else { installed = true }
    }
}
