import Darwin
import Foundation
import Shared

enum Log {
    /// One line to stderr (launchd redirects it to /var/log/computemanager-fand.log).
    @Sendable static func line(_ s: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        FileHandle.standardError.write(Data("\(ts) fand: \(s)\n".utf8))
    }
}

/// Watchdog clock: seconds since boot as a `Date`. Unaffected by wall-clock changes; only
/// differences between two values are meaningful (never put it on the wire).
enum Monotonic {
    static func now() -> Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }
}

/// Long-running daemon: SMC, controller, socket, tick timer, signals, wake.
final class Daemon: @unchecked Sendable {  // fields set once in run() on the main thread
    private var service: FandService?
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var power: PowerObserver?

    func run() -> Never {
        let smc: AppleSMC
        do { smc = try AppleSMC() } catch {
            Log.line("cannot open SMC: \(error)")
            exit(1)
        }
        // Force Auto before the slow temperature-key enumeration (FAN-6).
        let fansOnly = FanHardware.discover(smc, enumerateTemps: false)
        for e in fansOnly.setAuto() { Log.line("startup revert error: \(e)") }
        let hw = fansOnly.discoveringTemps()
        Log.line("start: fans=\(hw.fans.map { "\($0.id):\(Int($0.minRPM))-\(Int($0.maxRPM))" }) ftst=\(hw.hasFtst) "
                 + "temps Tp=\(hw.pcoreKeys.count) Te=\(hw.ecoreKeys.count) Tg=\(hw.gpuKeys.count)")
        let hub = StatusHub()
        let controller = FanController(hw: hw, log: Log.line, onChange: { hub.publish($0) })
        controller.start(now: Monotonic.now())  // FAN-6

        // Signals first, so a SIGTERM during startup still reverts.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                Log.line("signal \(sig): reverting to auto and exiting")
                self?.service?.stop()  // no more requests, then revert (controller ignores late ones)
                controller.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        let path = Paths.fandSocket
        if path == Paths.defaultFandSocket {
            mkdir(Paths.fandSocketDirectory, 0o755)
            chmod(Paths.fandSocketDirectory, 0o755)
        }
        let service = FandService(controller: controller, hub: hub, path: path)
        do { try service.start() } catch {
            Log.line("cannot listen on \(path): \(error)")
            controller.shutdown()
            exit(1)
        }
        self.service = service
        Log.line("listening on \(path)")

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fand.tick"))
        t.schedule(deadline: .now() + controller.curve.tick, repeating: controller.curve.tick, leeway: .milliseconds(100))
        t.setEventHandler { controller.tick(now: Monotonic.now()) }
        t.resume()
        timer = t

        let p = PowerObserver { controller.wake(now: Monotonic.now()) }
        if !p.start() { Log.line("warning: IORegisterForSystemPower failed; relying on per-tick re-apply") }
        power = p

        dispatchMain()
    }
}

/// One-shot CLI modes (no daemon, no socket).
enum OneShot {
    /// Read-only: print fans + temps as JSON. Works unprivileged; never writes the SMC.
    static func printStatus() -> Int32 {
        do {
            let smc = try AppleSMC()
            let hw = FanHardware.discover(smc)  // read-only: no setAuto here
            let s = FanStatus(mode: .auto, fans: hw.readFans(), temps: hw.readTemps(),
                              thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
                              lastHeartbeat: nil)
            let e = WireCoding.encoder()
            e.outputFormatting.insert(.prettyPrinted)
            print(String(decoding: try e.encode(s), as: UTF8.self))
            print("ftst=\(hw.hasFtst) Tp=\(hw.pcoreKeys.count) Te=\(hw.ecoreKeys.count) Tg=\(hw.gpuKeys.count) "
                  + "smcParamSize=\(AppleSMC.paramSize)")
            return 0
        } catch {
            Log.line("\(error)")
            return 1
        }
    }

    /// Force Auto (root). Used by uninstall.sh as a belt-and-braces step.
    static func revertAuto() -> Int32 {
        do {
            let hw = FanHardware.discover(try AppleSMC())
            let errors = hw.setAuto()
            for e in errors { Log.line(e) }
            print(errors.isEmpty ? "fans: auto" : "fans: revert had errors (run as root?)")
            return errors.isEmpty ? 0 : 1
        } catch {
            Log.line("\(error)")
            return 1
        }
    }
}
