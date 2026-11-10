import Foundation
import Testing
@testable import fand
import Shared

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func make(_ smc: FakeSMC, thermal: ThermalBox = ThermalBox()) -> FanController {
    FanController(hw: FanHardware.discover(smc), thermal: { thermal.value })
}

private func allAllowed(_ smc: FakeSMC) -> Bool {
    smc.writeLog.allSatisfy { FanHardware.isAllowedWrite($0.0) }
}

@Suite struct CurveTests {
    @Test func curveAndHysteresis() {
        var c = CurveState(curve: Defaults.fanCurve)
        #expect(c.fraction(50) == 0 && c.fraction(55) == 0 && c.fraction(70) == 0.5 && c.fraction(85) == 1 && c.fraction(99) == 1)
        #expect(c.update(70) == 70)
        #expect(c.update(68) == 70)   // inside dead band
        #expect(c.update(67) == 70)   // exactly hysteresis below
        #expect(c.update(66) == 69)   // lags by hysteresis
        #expect(c.update(75) == 75)   // rising follows at once
        c.reset()
        #expect(c.update(60) == 60)
        #expect(CurveState.rpm(fraction: 0.5, minRPM: 2317, maxRPM: 6800) == 4559)
    }
}

@Suite struct ControllerTests {
    @Test func startRevertsToAutoWithoutFtst() {
        let smc = FakeSMC()
        smc.set("F0Md", 1)
        let c = make(smc)
        c.start(now: t0)
        #expect(smc.value("F0Md") == 0 && smc.value("F1Md") == 0)
        #expect(!smc.writeLog.contains { $0.0 == "Ftst" })
        #expect(c.currentMode == .auto)
    }

    @Test func ftstUsedOnlyWhenPresent() {
        let smc = FakeSMC(ftst: true)
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        #expect(smc.value("Ftst") == 1)
        c.setMode(.auto, connection: 1, now: t0)
        #expect(smc.value("Ftst") == 0 && smc.value("F0Md") == 0)
        #expect(allAllowed(smc))
    }

    @Test func maxMode() {
        let smc = FakeSMC()
        let c = make(smc)
        let s = c.setMode(.max, connection: 1, now: t0)
        #expect(s.mode == .max)
        #expect(s.fans.allSatisfy { $0.control == .manual && $0.targetRPM == 6800 })
        #expect(allAllowed(smc))
    }

    @Test func performanceCurve() {
        let smc = FakeSMC(temps: ["Tp01": 50])
        let c = make(smc)
        c.setMode(.performance, connection: 1, now: t0)
        #expect(smc.value("F0Tg") == 2317 && smc.value("F0Md") == 1)
        smc.set("Tp01", 70)
        c.tick(now: t0 + 2)
        #expect(smc.value("F0Tg") == 4559 && smc.value("F1Tg") == 4559)
        smc.set("Tp01", 68)  // within hysteresis: unchanged
        c.tick(now: t0 + 2)
        #expect(smc.value("F0Tg") == 4559)
        smc.set("Tp01", 90)
        c.tick(now: t0 + 4)
        #expect(smc.value("F0Tg") == 6800)
        #expect(allAllowed(smc))
    }

    @Test func thermalSeriousForcesMax() {
        let smc = FakeSMC(temps: ["Tp01": 50])
        let th = ThermalBox()
        let c = make(smc, thermal: th)
        c.setMode(.performance, connection: 1, now: t0)
        #expect(smc.value("F0Tg") == 2317)
        th.value = .serious
        c.tick(now: t0 + 2)
        #expect(smc.value("F0Tg") == 6800)
        th.value = .fair
        c.tick(now: t0 + 4)
        #expect(smc.value("F0Tg") == 2317)
    }

    @Test func noSensorFailsSafeToMax() {
        let smc = FakeSMC(temps: ["Tp01": 500])
        let c = make(smc)
        c.setMode(.performance, connection: 1, now: t0)
        #expect(smc.value("F0Tg") == 6800)
    }

    @Test func watchdog() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        c.tick(now: t0 + 9)
        #expect(c.currentMode == .max)
        c.heartbeat(connection: 1, now: t0 + 8)
        c.tick(now: t0 + 17)
        #expect(c.currentMode == .max)
        let s = c.tick(now: t0 + 18.5)
        #expect(c.currentMode == .auto && s.mode == .auto)
        #expect(smc.value("F0Md") == 0 && smc.value("F1Md") == 0)
    }

    @Test func autoModeHasNoWatchdogWrites() {
        let smc = FakeSMC()
        let c = make(smc)
        c.start(now: t0)
        smc.clearWrites()
        c.tick(now: t0 + 100)
        #expect(smc.writeLog.isEmpty)
    }

    @Test func disconnectOfControlConnectionReverts() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        c.disconnected(connection: 2)  // e.g. subscribe-only connection
        #expect(c.currentMode == .max)
        c.disconnected(connection: 1)
        #expect(c.currentMode == .auto && smc.value("F0Md") == 0)
        // Reconnect + setMode works again.
        c.setMode(.performance, connection: 3, now: t0 + 1)
        #expect(c.currentMode == .performance)
    }

    @Test func heartbeatConnectionCountsAsControl() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        c.heartbeat(connection: 5, now: t0 + 1)
        c.disconnected(connection: 5)
        #expect(c.currentMode == .auto)
    }

    @Test func wakeAndTickReapply() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        smc.resetFans()
        c.wake(now: t0 + 1)
        #expect(smc.value("F0Md") == 1 && smc.value("F1Md") == 1 && smc.value("F0Tg") == 6800)
        smc.resetFans()
        smc.set("F0Tg", 2317)
        c.tick(now: t0 + 2)
        #expect(smc.value("F0Md") == 1 && smc.value("F0Tg") == 6800)
    }

    @Test func wakeInAutoRewritesAuto() {
        let smc = FakeSMC()
        let c = make(smc)
        c.start(now: t0)
        smc.set("F0Md", 1)
        c.wake(now: t0 + 1)
        #expect(smc.value("F0Md") == 0)
    }

    @Test func shutdownReverts() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.performance, connection: 1, now: t0)
        c.shutdown()
        #expect(c.currentMode == .auto && smc.value("F0Md") == 0 && smc.value("F1Md") == 0)
    }

    @Test func inputsAfterShutdownKeepAuto() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        c.shutdown()
        smc.clearWrites()
        c.setMode(.max, connection: 1, now: t0 + 1)
        c.heartbeat(connection: 1, now: t0 + 1)
        c.tick(now: t0 + 2)
        c.wake(now: t0 + 3)
        #expect(c.currentMode == .auto && smc.value("F0Md") == 0 && smc.value("F1Md") == 0)
        #expect(smc.writeLog.isEmpty)
    }

    @Test func heartbeatFromOtherConnectionDoesNotFeedWatchdog() {
        let smc = FakeSMC()
        let c = make(smc)
        c.setMode(.max, connection: 1, now: t0)
        c.heartbeat(connection: 2, now: t0 + 8)  // e.g. a second app instance
        c.tick(now: t0 + 11)
        #expect(c.currentMode == .auto && smc.value("F0Md") == 0)
        // The controlling connection's heartbeat does count.
        c.setMode(.max, connection: 2, now: t0 + 20)
        c.heartbeat(connection: 2, now: t0 + 28)
        c.tick(now: t0 + 31)
        #expect(c.currentMode == .max)
    }

    @Test func wallClockJumpBackDoesNotDisableWatchdog() {
        let smc = FakeSMC()
        let wall = DateBox(t0)
        let c = FanController(hw: FanHardware.discover(smc), thermal: { .nominal }, wallClock: { wall.value })
        let mono = Date(timeIntervalSinceReferenceDate: 500)  // watchdog clock (uptime)
        c.setMode(.max, connection: 1, now: mono)
        wall.value = t0 - 3600  // user sets the clock back an hour
        c.tick(now: mono + 11)
        #expect(c.currentMode == .auto)
        #expect(c.status().lastHeartbeat == t0)  // display uses the wall clock
    }

    @Test func startupDiscoveryCanSkipTemps() {
        let smc = FakeSMC(temps: ["Tp01": 50])
        let hw = FanHardware.discover(smc, enumerateTemps: false)
        #expect(hw.fans.count == 2 && hw.pcoreKeys.isEmpty)
        let full = hw.discoveringTemps()
        #expect(full.fans == hw.fans && full.pcoreKeys == ["Tp01"])
    }

    @Test func failedWritesDoNotCrashAndRevertTriesAllFans() {
        let smc = FakeSMC()
        let c = make(smc)
        smc.failWrites = true
        let s = c.setMode(.max, connection: 1, now: t0)
        #expect(s.mode == .max)
        #expect(c.hw.setAuto().count == 2)
    }

    @Test func statusReportsFansAndHeartbeat() {
        let smc = FakeSMC(temps: ["Tp01": 61, "Te05": 40, "Tg0f": 45])
        let c = FanController(hw: FanHardware.discover(smc), thermal: { .nominal }, wallClock: { t0 })
        c.setMode(.auto, connection: 1, now: t0)
        c.heartbeat(connection: 1, now: t0 + 1)
        let s = c.status()
        #expect(s.fans.count == 2 && s.fans[0].minRPM == 2317 && s.fans[0].maxRPM == 6800 && s.fans[0].actualRPM == 2400)
        #expect(s.temps == Temperatures(pcoreMax: 61, ecoreMax: 40, gpuMax: 45))
        #expect(s.lastHeartbeat == t0 && s.curve == Defaults.fanCurve)
    }
}

final class DateBox: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var d: Date
    init(_ d: Date) { self.d = d }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return d }
        set { lock.lock(); d = newValue; lock.unlock() }
    }
}
