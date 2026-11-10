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
