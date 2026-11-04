import XCTest
@testable import ShowKit

final class ParameterSpecTests: XCTestCase {
    func testLinearAndLogRangesRoundTrip() {
        let gain = ParameterSpec(-15, 15, unit: "dB")
        XCTAssertEqual(gain.value(at: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(gain.position(for: 6), 0.7, accuracy: 1e-9)

        let freq = ParameterSpec(20, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
        XCTAssertEqual(freq.value(at: 0.5), 20 * sqrt(1000), accuracy: 1e-6)
        for i in 0...100 {
            let p = Double(i) / 100
            XCTAssertEqual(freq.position(for: freq.value(at: p)), p, accuracy: 1e-9)
        }
    }

    func testARangeCanRunDownwards() {
        // X32's EQ Q: 10 at the bottom, 0.3 at the top.
        let q = ParameterSpec(10, 0.3, curve: .logarithmic)
        XCTAssertEqual(q.value(at: 0), 10, accuracy: 1e-9)
        XCTAssertEqual(q.value(at: 1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(q.position(for: 0.3), 1, accuracy: 1e-9)
    }

    func testFormatsFrequenciesInKilohertz() {
        let freq = ParameterSpec(20, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
        XCTAssertEqual(freq.text(at: 0), "20 Hz")
        XCTAssertEqual(freq.text(at: 1), "20.00 kHz")
        XCTAssertEqual(ParameterSpec(-60, 0, unit: "dB").text(at: 0.5), "-30.0 dB")
    }

    func testMeterScale() {
        XCTAssertEqual(MeterReading.position(decibels: 0), 1)
        XCTAssertEqual(MeterReading.position(decibels: -30), 0.5)
        XCTAssertEqual(MeterReading.position(decibels: -90), 0)
        XCTAssertEqual(MeterReading.position(amplitude: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(MeterReading.position(amplitude: 0), 0)
    }
}

@MainActor
final class BehringerProcessingTests: XCTestCase {
    func testSendsProcessingOnTheMixersOwnScales() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerX32), transport: net.factory)
        driver.start()
        driver.send("ch/01.eq.1.freq", .level(0.5))
        driver.send("ch/01.comp.ratio", .number(3))
        driver.send("ch/01.gate.on", .on(true))
        driver.send("ch/01.gain", .level(0.25))
        driver.send("ch/32.hpf.freq", .level(1))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/01/eq/1/f", [.float(0.5)]),
            OSCMessage("/ch/01/dyn/ratio", [.int(3)]),
            OSCMessage("/ch/01/gate/on", [.int(1)]),
            OSCMessage("/headamp/000/gain", [.float(0.25)]),
            OSCMessage("/ch/32/preamp/hpf", [.float(1)])
        ])
    }

    func testReadsAStripsProcessingWhenItsDetailOpens() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerXAir), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        driver.detailOpened("ch/05")
        let queried = net.last.sentOSC
        XCTAssertEqual(queried.count, 47) // input 3, gate 7, compressor 13, EQ 17, pan and 6 sends 7
        XCTAssertTrue(queried.allSatisfy { $0.arguments.isEmpty && $0.address.hasPrefix("/ch/05/") })

        net.last.reply(OSCMessage("/ch/05/dyn/ratio", [.int(5)]))
        net.last.reply(OSCMessage("/ch/05/eq/on", [.int(1)]))
        net.last.reply(OSCMessage("/headamp/05/gain", [.float(0.5)]))
        XCTAssertEqual(sink.values["ch/05.comp.ratio"], .number(5))
        XCTAssertEqual(sink.values["ch/05.eq.on"], .on(true))
        XCTAssertEqual(sink.values["ch/05.gain"], .level(0.5))
        XCTAssertEqual(driver.groups[0].strips[4].gain?.id, "ch/05.gain")
    }

    func testReadsXAirMeters() {
        var blob = Data([40, 0, 0, 0])
        for i in 0..<40 {
            let dB: Double = i == 0 ? 0 : i == 36 ? -30 : -120
            let raw = UInt16(bitPattern: Int16(dB * 256))
            blob.append(contentsOf: [UInt8(raw & 0xFF), UInt8(raw >> 8)])
        }
        let readings = BehringerDriver.meterReadings(blob, x32: false)
        XCTAssertEqual(readings?["ch/01"], MeterReading(input: 1))
        XCTAssertEqual(readings?["ch/02"], MeterReading(input: 0))
        XCTAssertEqual(readings?["lr"], MeterReading(output: 0.5))
        XCTAssertEqual(readings?["bus/1"], MeterReading(output: 0))
    }

    func testRenewsTheMeterSubscriptionAndPassesMetersOn() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerXAir), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertTrue(net.last.sentOSC.contains(OSCMessage("/meters", [.string("/meters/1"), .int(0)])))
        var blob = Data([40, 0, 0, 0])
        blob.append(Data(repeating: 0, count: 80)) // everything at 0 dB
        net.last.reply(OSCMessage("/meters/1", [.blob(blob)]))
        XCTAssertEqual(sink.meters["ch/16"]?.input, 1)
        driver.stop()
    }
}

@MainActor
final class DLiveProcessingTests: XCTestCase {
    func testSendsEQHighPassAndPreampGain() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathDLive), transport: net.factory)
        driver.start()
        driver.send("ip.2.eq.1.gain", .level(1))
        driver.send("ip.2.hpf.on", .on(true))
        driver.send("ip.1.eq.2.type", .number(1))
        driver.send("ip.3.gain", .level(0))
        XCTAssertEqual(net.last.sent.map { [UInt8]($0) }, [
            [0xB0, 0x63, 0x01, 0xB0, 0x62, 0x1D, 0xB0, 0x06, 0x7F],
            [0xB0, 0x63, 0x01, 0xB0, 0x62, 0x31, 0xB0, 0x06, 0x40],
            [0xB0, 0x63, 0x00, 0xB0, 0x62, 0x1E, 0xB0, 0x06, 0x01],
            [0xE0, 0x02, 0x00]
        ])
    }

    func testReportsProcessingAndGain() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathDLive), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        driver.detailOpened("ip.1")
        XCTAssertEqual(net.last.sent.count, AllenHeathDLiveDriver.inputParams.count)
        net.last.reply(Data([0xB0, 0x63, 0x04, 0xB0, 0x62, 0x1B, 0xB0, 0x06, 0x7F])) // ip.5 band 1 frequency at the top
        net.last.reply(Data([0xE0, 0x04, 100])) // socket 5 gain
        XCTAssertEqual(sink.values["ip.5.eq.1.freq"], .level(1))
        XCTAssertEqual(sink.values["ip.5.gain"]!.level!, 100.0 / 127, accuracy: 1e-9)
    }
}

@MainActor
final class YamahaProcessingTests: XCTestCase {
    func testBuildsProcessingFromWhatTheConsoleReports() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.yamahaRCP) { $0.variant = "dm3" }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        for line in [
            #"OK prminfo 21 "IO:Current/InCh/HAGain" 16 1 0 64 0 "dB" integer any rw 1"#,
            #"OK prminfo 26 "MIXER:Current/InCh/PEQ/On" 16 1 0 1 1 "" integer any rw 1"#,
            #"OK prminfo 29 "MIXER:Current/InCh/PEQ/Band/Freq" 16 4 200 200000 200 "" integer any rw 10"#,
            #"OK prminfo 30 "MIXER:Current/InCh/PEQ/Band/Gain" 16 4 -1800 1800 0 "" integer any rw 100"#,
            #"OK prminfo 207 "MIXER:Current/InCh/Dyna1/Type" 16 1 0 10 "Gate" "" string any rw 1"#,
            #"OK prminfo 208 "MIXER:Current/InCh/Dyna1/Threshold" 16 1 -720 0 -260 "" integer any rw 10"#
        ] {
            net.last.reply(line: line)
        }
        (driver as! YamahaRCPDriver).buildProcessing()
        XCTAssertEqual(sink.layoutChanges, 1)

        let strip = driver.groups[0].strips[0]
        XCTAssertEqual(strip.gain?.id, "inch.1.gain.InCh.HAGain.0")
        XCTAssertEqual(strip.sections.map(\.title), ["EQ", "Gate"])
        XCTAssertEqual(strip.sections[0].eq?.bands.count, 4) // drawn as a curve, from the console's own bands
        XCTAssertEqual(strip.sections[0].eq?.on, "inch.1.eq.PEQ.On.0")
        XCTAssertEqual(strip.sections[0].controls.count, 9) // on, and frequency and gain for 4 bands
        XCTAssertEqual(strip.sections[1].controls.map(\.label), ["Threshold"]) // Type is a string: left out

        net.last.clear()
        driver.send("inch.2.eq.Band.Freq.1", .level(1))
        driver.send("inch.1.gain.InCh.HAGain.0", .level(0.5))
        driver.send("inch.1.gate.Dyna1.Threshold.0", .level(0))
        XCTAssertEqual(net.last.sentLines, [
            "set MIXER:Current/InCh/PEQ/Band/Freq 1 1 200000",
            "set IO:Current/InCh/HAGain 0 0 32",
            "set MIXER:Current/InCh/Dyna1/Threshold 0 0 -720"
        ])

        net.last.reply(line: #"NOTIFY set MIXER:Current/InCh/PEQ/Band/Gain 2 0 600 "6.00""#)
        XCTAssertEqual(sink.values["inch.3.eq.Band.Gain.0"]!.level!, 24.0 / 36, accuracy: 1e-9)
    }

    func testReadsMeters() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.yamahaRCP) { $0.variant = "dm3" }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.reply(line: "NOTIFY mtr MIXER:Current/Meter/InCh/PreFader mtr 7f 00 40")
        net.last.reply(line: "NOTIFY mtr MIXER:Current/Meter/St/PostOn mtr 7f")
        XCTAssertEqual(sink.meters["inch.1"]?.input, 1)
        XCTAssertEqual(sink.meters["inch.2"]?.input, 0)
        XCTAssertEqual(sink.meters["inch.3"]!.input!, 64.0 / 127, accuracy: 1e-9)
        XCTAssertEqual(sink.meters["st"]?.output, 1)
        driver.stop()
    }
}

@MainActor
final class GrandMA3ColumnTests: XCTestCase {
    func testColumnsShowTheChosenRowsInConsoleOrder() {
        let net = FakeNetwork()
        let usual = Drivers.make(config(.grandMA3), transport: net.factory).groups[0].strips[0]
        XCTAssertEqual(usual.fader?.id, "exec.201.level")
        XCTAssertEqual(usual.buttons.map(\.id), ["exec.201.key"])
        XCTAssertEqual(usual.lowerButtons.map(\.id), ["exec.101.key"]) // the key under the fader

        let full = Drivers.make(config(.grandMA3) { $0.executorRows = [1, 2, 3, 4]; $0.firstNumber = 3 }, transport: net.factory)
        XCTAssertEqual(full.groups[0].strips[0].buttons.map(\.id),
                       ["exec.403.level", "exec.403.key", "exec.303.level", "exec.303.key", "exec.203.key"])
        XCTAssertEqual(full.groups[0].strips.count, 15)
    }

    func testKeysCanBeSetToSendCommands() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3), transport: net.factory)
        driver.start()
        driver.apply(customizations: ["col.1": StripCustomization(actions: ["exec.101.key": "toggle"])])
        driver.send("exec.101.key", .press(true))
        driver.send("exec.101.key", .press(false))
        driver.send("exec.201.key", .press(true))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/gma3/cmd", [.string("Toggle Executor 1.101")]),
            OSCMessage("/gma3/Page1/Key201", [.int(1)])
        ])
    }

    func testCueTools() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3), transport: net.factory)
        driver.start()
        driver.send("exec.201.goto", .text("5.5"))
        driver.send("exec.201.goto", .text("5; Off")) // not a cue number: ignored
        driver.send("exec.201.cuefade", .text("5 3/6"))
        driver.send("exec.201.update", .text("7"))
        driver.send("exec.201.back", .trigger)
        XCTAssertEqual(net.last.sentOSC.compactMap { $0.arguments.first?.string }, [
            "Goto Cue 5.5 Executor 1.201",
            "Select Executor 1.201",
            "Cue 5 CueFade 3/6",
            "Select Executor 1.201",
            "Store Cue 7 /Merge",
            "Go- Executor 1.201"
        ])
    }

    func testFollowsThePluginsFeedback() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.reply(OSCMessage("/gma3/Page1/Name201", [.string("Front Wash")]))
        net.last.reply(OSCMessage("/gma3/Page1/Active101", [.int(1)]))
        net.last.reply(OSCMessage("/gma3/Page1/Cue201", [.string("3 Verse")]))
        net.last.reply(OSCMessage("/gma3/Page1/NextCue201", [.string("-")]))
        XCTAssertEqual(sink.names["col.1"], "Front Wash")
        XCTAssertEqual(sink.info["exec.201.name"], "Front Wash")
        XCTAssertEqual(sink.info["exec.101.active"], "1")
        XCTAssertEqual(sink.info["exec.201.cue"], "3 Verse")
        XCTAssertNil(sink.info["exec.201.next"])

        // The desk moves to page 2: the app follows, and page 1's info goes.
        net.last.reply(OSCMessage("/gma3/CurrentPage", [.int(2)]))
        XCTAssertNil(sink.info["exec.201.name"])
        XCTAssertEqual(sink.names["col.1"], "")
        net.last.clear()
        driver.send("exec.201.level", .level(1))
        XCTAssertEqual(net.last.sentOSC, [OSCMessage("/gma3/Page2/Fader201", [.float(100)])])
    }

    func testOpensOlderShowsThatCountedFromExecutor201() throws {
        let json = #"{"kind":"grandMA3","host":"10.1.1.1","firstNumber":201,"count":10}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.firstNumber, 1)
        XCTAssertEqual(config.executorRows, [1, 2])
    }
}

@MainActor
final class CustomizationTests: XCTestCase {
    func testRenamingDoesntReconnect() {
        let net = FakeNetwork()
        let device = Device(config: config(.behringerX32), transport: net.factory)
        device.connect()
        let transports = net.transports.count
        var changed = device.config
        changed.customizations["ch/01"] = StripCustomization(name: "Kick", color: "red")
        device.update(changed)
        XCTAssertEqual(net.transports.count, transports)
        XCTAssertEqual(device.displayName(of: device.groups[0].strips[0]), "Kick")
        XCTAssertEqual(device.customization("ch/01").color, "red")
    }

    func testMetersMergeInputsAndOutputs() {
        let net = FakeNetwork()
        let device = Device(config: config(.yamahaRCP) { $0.variant = "dm3" }, transport: net.factory)
        device.connect()
        net.last.reply(line: "NOTIFY mtr MIXER:Current/Meter/InCh/PreFader mtr 7f")
        net.last.reply(line: "NOTIFY mtr MIXER:Current/Meter/InCh/PostOn mtr 00")
        XCTAssertEqual(device.meterState("inch.1").reading, MeterReading(input: 1, output: 0))
    }
}
