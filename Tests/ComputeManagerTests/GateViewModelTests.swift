import Foundation
import Shared
import Testing
@testable import ComputeManager

@MainActor @Suite struct GateViewModelTests {
    func make(_ fake: FakeGate) -> GateViewModel {
        GateViewModel(backend: fake, initial: fake.status)
    }

    @Test func offWithoutJobsGoesStraightToNoMore() async {
        let fake = FakeGate()
        let vm = make(fake)
        await vm.setOn(false)
        #expect(!vm.offChoicePending)
        #expect(vm.status.level == .noMore)
        #expect(fake.requests == [.setGate(SetGateRequest(level: .noMore))])
    }

    @Test func offWithJobsAsksThenApplies() async {
        let fake = FakeGate(leases: [lease()])
        let vm = make(fake)
        await vm.setOn(false)
        #expect(vm.offChoicePending)
        #expect(fake.requests.isEmpty)
        await vm.chooseOff(.softStop)
        #expect(!vm.offChoicePending)
        #expect(vm.status.level == .softStop)
        #expect(vm.escalations == [.hardStop])
    }

    @Test func cancelKeepsGateOn() async {
        let fake = FakeGate(leases: [lease()])
        let vm = make(fake)
        await vm.setOn(false)
        vm.cancelOffChoice()
        #expect(!vm.offChoicePending)
        #expect(vm.isOn)
        #expect(fake.requests.isEmpty)
    }

    @Test func escalation() async {
        let fake = FakeGate(leases: [lease()], level: .noMore)
        let vm = make(fake)
        #expect(vm.escalations == [.softStop, .hardStop])
        await vm.chooseOff(.hardStop)
        #expect(vm.escalations.isEmpty)
        // No jobs → nothing to escalate.
        #expect(make(FakeGate(level: .noMore)).escalations.isEmpty)
        #expect(make(FakeGate(leases: [lease()])).escalations.isEmpty)
    }

    @Test func slotsKeepLevel() async {
        let fake = FakeGate(level: .noMore)
        let vm = make(fake)
        await vm.setSlots(3)
        #expect(fake.requests == [.setGate(SetGateRequest(level: .noMore, slots: 3))])
        #expect(vm.status.slots == 3)
        await vm.setSlots(0)
        #expect(vm.status.slots == 1)
    }

    @Test func killAndPersist() async {
        let l = lease()
        let fake = FakeGate(leases: [l])
        let vm = make(fake)
        var saved: [GateStore.Snapshot] = []
        vm.onPersist = { saved.append($0) }
        await vm.kill(l.jobId)
        #expect(vm.status.leases.first?.state == .killing)
        #expect(saved.isEmpty)
        await vm.setOn(false)
        await vm.chooseOff(.noMore)
        #expect(saved.last?.level == .noMore)
    }

    @Test func errorsSurface() async {
        let vm = make(FakeGate())
        await vm.kill(UUID())
        #expect(vm.lastError == "unknown job")
    }

    @Test func meetingPreset() async {
        let fake = FakeGate(leases: [lease()])
        let link = FakeFanLink()
        let app = AppModel(gate: make(fake), fan: FanViewModel(link: link))
        app.fan.select(.max)
        await app.meeting()
        #expect(fake.requests == [.meeting])
        #expect(app.gate.status.level == .noMore)
        #expect(app.fan.mode == .auto)
        #expect(link.modes == [.max, .auto])
    }

    @Test func storeNormalisesStopLevels() throws {
        let url = URL(fileURLWithPath: "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GateStore(url: url)
        #expect(store.load().level == .on)
        var s = GateSettings()
        s.slots = 4
        store.save(.init(settings: s, level: .hardStop))
        #expect(store.load() == .init(settings: s, level: .noMore))
    }

    @Test func storeKeepsBackupOfUnreadableFile() throws {
        let url = URL(fileURLWithPath: "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).json")
        let store = GateStore(url: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.backupURL)
        }
        let junk = Data("{not json".utf8)
        try junk.write(to: url)
        #expect(store.load() == .init(settings: GateSettings(), level: .on))
        #expect(try Data(contentsOf: store.backupURL) == junk)
        store.save(.init(settings: GateSettings(), level: .noMore))
        #expect(try Data(contentsOf: store.backupURL) == junk)
    }

    @Test func closingMenuCancelsPendingOffChoice() async {
        let fake = FakeGate(leases: [lease()])
        let app = AppModel(gate: make(fake), fan: FanViewModel(link: FakeFanLink()))
        await app.gate.setOn(false)
        #expect(!app.gate.switchOn)
        app.gate.cancelOffChoice()  // MenuContent.onDisappear
        #expect(app.gate.switchOn)
        #expect(fake.requests.isEmpty)
    }

    @Test func staleSnapshotsDropped() {
        let vm = make(FakeGate())
        var newer = vm.status
        newer.slots = 5
        var older = vm.status
        older.slots = 3
        vm.apply(newer, seq: .max - 1)
        vm.apply(older, seq: 1)
        #expect(vm.status.slots == 5)
    }

    @Test func capBoundedAndDefaultFollows() {
        var s = GateSettings()
        s.defaultMaxRuntimeSeconds = 40 * 60
        s = SettingsView.setting(s, \.maxRuntimeCapSeconds, minutes: 240)
        #expect(s.maxRuntimeCapSeconds == Defaults.maxRuntimeCap)
        s = SettingsView.setting(s, \.maxRuntimeCapSeconds, minutes: 30)
        #expect(s.maxRuntimeCapSeconds == 30 * 60)
        #expect(s.defaultMaxRuntimeSeconds == 30 * 60)
        s = SettingsView.setting(s, \.defaultMaxRuntimeSeconds, minutes: 90)
        #expect(s.defaultMaxRuntimeSeconds == 30 * 60)
        #expect(SettingsView.capLimit == 60)
    }

    @Test func nonAutoFanModeHoldsActivity() {
        let fan = FanViewModel(link: FakeFanLink())
        fan.select(.performance)
        #expect(fan.activity != nil)
        fan.select(.max)
        #expect(fan.activity != nil)
        fan.select(.auto)
        #expect(fan.activity == nil)
    }

    @Test func curveClampedPersistedAndSent() {
        let link = FakeFanLink()
        let saved = Locked<FanCurve?>(nil)
        let fan = FanViewModel(link: link)
        fan.onPersistCurve = { saved.set($0) }
        fan.start()
        #expect(link.curves == [Defaults.fanCurve])
        fan.select(.performance)
        fan.setCurve(FanCurve(lowTemp: 60, highTemp: 62, hysteresis: 3, tick: 9))
        let want = FanCurve(lowTemp: 60, highTemp: 65, hysteresis: 3, tick: Defaults.fanCurve.tick)
        #expect(fan.curve == want && saved.get() == want)
        #expect(link.modes.last == .performance && link.curves.last == want)
        let n = link.modes.count
        fan.setCurve(want)  // unchanged: nothing sent
        #expect(link.modes.count == n)
        // Old fand keeps reporting the default curve.
        fan.apply(FanStatus(mode: .performance, fans: [], temps: Temperatures(), thermalState: .nominal,
                            lastHeartbeat: nil))
        #expect(fan.curveNotApplied)
        fan.setCurve(Defaults.fanCurve)
        #expect(!fan.curveNotApplied)
    }

    @Test func fanStoreRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cm-fan-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FanStore(url: url)
        #expect(store.load() == Defaults.fanCurve)
        let c = FanCurve(lowTemp: 50, highTemp: 90, hysteresis: 1, tick: 2)
        store.save(c)
        #expect(store.load() == c)
    }

    @Test func patternParsing() {
        #expect(SettingsView.parse(" make \n\npytest\nmake\n") == ["make", "pytest"])
    }
}

@Suite struct MenuBarIconTests {
    @Test func symbols() {
        let on = MenuBarIcon.State(level: .on, jobsRunning: false, fanMode: .auto, fanReachable: true)
        #expect(MenuBarIcon.symbols(for: on).map(\.first) == ["bolt.fill"])
        var s = on
        s.level = .softStop
        s.jobsRunning = true
        s.fanMode = .max
        #expect(MenuBarIcon.symbols(for: s).map(\.first) == ["bolt.badge.clock.fill", "wind"])
        s.fanReachable = false
        s.jobsRunning = false
        #expect(MenuBarIcon.symbols(for: s).map(\.first) == ["bolt.slash.fill"])
    }
}
