import Foundation
import Testing
@testable import fand
import Shared

@Suite struct SMCTests {
    @Test func codecRoundTrips() throws {
        for (t, v) in [("flt ", 6800.0), ("ui8 ", 1), ("ui16", 513), ("ui32", 70000), ("fpe2", 2317.25)] {
            #expect(try SMCCodec.decode(t, SMCCodec.encode(t, v)) == v)
        }
        #expect(try SMCCodec.decode("sp78", [0x32, 0x80]) == 50.5)
        #expect(try SMCCodec.decode("si8 ", [0xff]) == -1)
        #expect(try SMCCodec.encode("ui8 ", 300) == [255])
        #expect(try SMCCodec.encode("ui8 ", -4) == [0])
        #expect(throws: SMCError.self) { try SMCCodec.encode("flt ", .nan) }
        #expect(throws: SMCError.self) { try SMCCodec.decode("flt ", [0, 0]) }
        #expect(throws: SMCError.self) { try SMCCodec.encode("sp78", 1) }
    }

    @Test func fourCC() {
        #expect(smcString(smcFourCC("F0Md")) == "F0Md")
    }

    @Test func allowlist() {
        for k in ["F0Md", "F1Tg", "F9Md", "Ftst"] { #expect(FanHardware.isAllowedWrite(k), "\(k)") }
        for k in ["F0Mx", "F0Mn", "F0Ac", "FNum", "F10M", "FaMd", "Tp01", "F0Md ", "", "#KEY"] {
            #expect(!FanHardware.isAllowedWrite(k), "\(k)")
        }
    }

    @Test func discovery() {
        let smc = FakeSMC(temps: ["Tp01": 60, "Tp05": 200, "Tp09": -3, "Te05": 41, "Tg0f": 44, "TB0T": 30])
        let hw = FanHardware.discover(smc)
        #expect(hw.fans == [FanSpec(id: 0, minRPM: 2317, maxRPM: 6800), FanSpec(id: 1, minRPM: 2317, maxRPM: 6800)])
        #expect(!hw.hasFtst)
        #expect(hw.pcoreKeys == ["Tp01", "Tp05", "Tp09"])
        // Implausible readings (200, -3) skipped; TB0T not a core sensor.
        #expect(hw.readTemps() == Temperatures(pcoreMax: 60, ecoreMax: 41, gpuMax: 44))
        #expect(FanHardware.discover(FakeSMC(ftst: true)).hasFtst)
    }

    @Test func manualClampsAndSkipsUnchanged() {
        let smc = FakeSMC()
        let hw = FanHardware.discover(smc)
        hw.setManual([0: 10_000, 1: 100], current: hw.readFans())
        #expect(smc.value("F0Tg") == 6800 && smc.value("F1Tg") == 2317)
        #expect(smc.value("F0Md") == 1 && smc.value("F1Md") == 1)
        smc.clearWrites()
        hw.setManual([0: 6800, 1: 2317], current: hw.readFans())
        #expect(smc.writeLog.isEmpty)
    }
}
