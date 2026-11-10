import AppKit
import Foundation
import GateCore
import Observation
import Shared

/// Owns the gate + fan view models and the actions that span both.
@MainActor @Observable
final class AppModel {
    let gate: GateViewModel
    let fan: FanViewModel

    init(gate: GateViewModel, fan: FanViewModel) {
        self.gate = gate
        self.fan = fan
    }

    /// Meeting preset (UI-9): gate No more + fans Auto, one click.
    func meeting() async {
        fan.select(.auto)
        await gate.meeting()
    }

    var icon: MenuBarIcon.State {
        MenuBarIcon.State(level: gate.status.level, jobsRunning: !gate.runningJobs.isEmpty,
                          fanMode: fan.mode, fanReachable: fan.reachable)
    }
}

/// Process-wide wiring: real GateService + fand link + gate socket server.
@MainActor
enum AppRuntime {
    static let model: AppModel = {
        let store = GateStore.standard
        let snap = store.load()
        let service = GateService(settings: snap.settings, level: snap.level)
        backend = service
        let demo = ProcessInfo.processInfo.environment["COMPUTEMANAGER_DEMO"] == "1"
        let gate = GateViewModel(backend: demo ? DemoGate() : service,
                                 initial: .initial(settings: snap.settings, level: snap.level))
        gate.onPersist = { store.save($0) }
        let link = FanLink()
        let fan = FanViewModel(link: link, socketPath: link.path)
        return AppModel(gate: gate, fan: fan)
    }()

    private static var backend: GateService?
    private static var server: GateServer?

    /// Start serving gate.sock and talking to fand. Quits with an alert if another
    /// instance already serves the gate socket.
    static func launch() {
        let m = model
        guard let service = backend else { return }
        let srv = service.makeServer()
        do {
            try srv.start()
        } catch SocketError.alreadyRunning {
            let a = NSAlert()
            a.messageText = "Compute Manager is already running"
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("ComputeManager: gate socket failed: \(error)")
        }
        server = srv
        launched = true
        m.fan.start()
        Task { await m.gate.refresh() }
        if let out = ProcessInfo.processInfo.environment["COMPUTEMANAGER_SNAPSHOT"] {
            Snapshot.write(model: m, to: out)
        }
    }

    /// Only an instance that actually launched touches fans (a duplicate must not reset them).
    private static var launched = false

    static func terminate() {
        guard launched else { return }
        model.fan.shutdown()
        server?.stop()
    }
}
