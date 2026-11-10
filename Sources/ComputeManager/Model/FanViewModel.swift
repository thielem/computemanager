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

    init(link: FanControlling, socketPath: String? = nil) {
        self.link = link
        self.socketPath = socketPath
        link.onStatus = { [weak self] s in
            Task { @MainActor in self?.apply(s) }
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
    }

    func shutdown() { link.shutdown() }

    func apply(_ s: FanStatus?) {
        status = s
        if s == nil, let p = socketPath { installed = FileManager.default.fileExists(atPath: p) }
        else { installed = true }
    }
}
