import XCTest
@testable import ShowKit

@MainActor
final class BehringerDriverTests: XCTestCase {
    func testWaitsForTheMixerToAnswerThenReadsEverything() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerX32), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 10023, listenPort: nil))

        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connecting) // UDP being "ready" proves nothing
        XCTAssertEqual(net.last.sentOSC.map(\.address), ["/xremote", "/xinfo"])

        net.last.clear()
        net.last.reply(OSCMessage("/xinfo", [.string("10.0.0.5"), .string("X32"), .string("X32"), .string("4.06")]))
        XCTAssertEqual(sink.states.last, .connected)
        // Queries are addresses without arguments; the first batch goes at once.
        XCTAssertFalse(net.last.sentOSC.isEmpty)
        XCTAssertTrue(net.last.sentOSC.allSatisfy { $0.arguments.isEmpty })
        driver.stop()
    }

    func testReportsFadersMutesAndNames() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerX32), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        net.last.reply(OSCMessage("/ch/01/mix/fader", [.float(0.75)]))
        net.last.reply(OSCMessage("/ch/01/mix/on", [.int(0)]))
        net.last.reply(OSCMessage("/ch/01/config/name", [.string("Kick")]))
        net.last.reply(OSCMessage("/dca/3/on", [.int(1)]))
        net.last.reply(OSCMessage("/config/mute/2", [.int(1)]))
        XCTAssertEqual(sink.values["ch/01.level"], .level(0.75))
        XCTAssertEqual(sink.values["ch/01.mute"], .on(true)) // on = 0 means muted
        XCTAssertEqual(sink.names["ch/01"], "Kick")
        XCTAssertEqual(sink.values["dca/3.mute"], .on(false))
        XCTAssertEqual(sink.values["mutegroup.2.mute"], .on(true))
        driver.stop()
    }

    func testSendsFadersMutesAndScenes() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerX32), transport: net.factory)
        driver.start()
        driver.send("ch/12.level", .level(0.5))
        driver.send("main/st.mute", .on(true))
        driver.send("bus/03.mute", .on(false))
        driver.send("scene", .number(4))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/12/mix/fader", [.float(0.5)]),
            OSCMessage("/main/st/mix/on", [.int(0)]),
            OSCMessage("/bus/03/mix/on", [.int(1)]),
            OSCMessage("/-action/goscene", [.int(4)])
        ])
    }

    func testXAirUsesItsOwnAddresses() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerXAir), transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 10024, listenPort: nil))
        driver.send("lr.level", .level(0.75))
        driver.send("rtn/2.mute", .on(true))
        driver.send("scene", .number(3))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/lr/mix/fader", [.float(0.75)]),
            OSCMessage("/rtn/2/mix/on", [.int(0)]),
            OSCMessage("/-snap/load", [.int(3)])
        ])
        XCTAssertEqual(driver.groups.first?.strips.count, 17) // 16 channels and the aux in
    }
}

@MainActor
final class AllenHeathSQDriverTests: XCTestCase {
    func testLinearTaperLevels() {
        XCTAssertTrue(AllenHeathSQDriver.wireLevel(decibels: nil) == (0, 0))
        // 0 dB is 15196 = 0x76 << 7 | 0x5C
        XCTAssertTrue(AllenHeathSQDriver.wireLevel(decibels: 0) == (0x76, 0x5C))
        XCTAssertEqual(AllenHeathSQDriver.decibels(vc: 0x76, vf: 0x5C)!, 0, accuracy: 0.01)
        XCTAssertNil(AllenHeathSQDriver.decibels(vc: 0, vf: 0))
    }

    func testSendsInputToLRLevelAndMute() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathSQ) { $0.midiChannel = 2 }, transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 51325))
        driver.send("ip.3.level", .level(AudioTaper.unity))
        driver.send("ip.3.mute", .on(true))
        XCTAssertEqual(net.last.sent.map { [UInt8]($0) }, [
            [0xB1, 0x63, 0x40, 0xB1, 0x62, 0x02, 0xB1, 0x06, 0x76, 0xB1, 0x26, 0x5C],
            [0xB1, 0x63, 0x00, 0xB1, 0x62, 0x02, 0xB1, 0x06, 0x00, 0xB1, 0x26, 0x01]
        ])
    }

    func testSendsMastersAndScenes() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathSQ), transport: net.factory)
        driver.start()
        driver.send("dca.2.mute", .on(false)) // DCA mutes start at 0x02:0x00
        driver.send("mix.1.level", .level(0)) // mix masters start at 0x4F:0x01
        driver.send("scene", .number(130))
        XCTAssertEqual(net.last.sent.map { [UInt8]($0) }, [
            [0xB0, 0x63, 0x02, 0xB0, 0x62, 0x01, 0xB0, 0x06, 0x00, 0xB0, 0x26, 0x00],
            [0xB0, 0x63, 0x4F, 0xB0, 0x62, 0x01, 0xB0, 0x06, 0x00, 0xB0, 0x26, 0x00],
            [0xB0, 0x00, 0x01, 0xC0, 0x01]
        ])
    }

    func testReadsStateOnConnectAndReportsReplies() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathSQ), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connected)
        // A get is the parameter, then CC 0x60 with 0x7F.
        XCTAssertEqual(Array([UInt8](net.last.sent[0]).suffix(3)), [0xB0, 0x60, 0x7F])

        net.last.reply(Data([0xB0, 0x63, 0x40, 0xB0, 0x62, 0x00, 0xB0, 0x06, 0x76, 0xB0, 0x26, 0x5C]))
        net.last.reply(Data([0xB0, 0x63, 0x00, 0x62, 0x00, 0x06, 0x00, 0x26, 0x01])) // running status
        XCTAssertEqual(sink.values["ip.1.level"]!.level!, AudioTaper.unity, accuracy: 0.001)
        XCTAssertEqual(sink.values["ip.1.mute"], .on(true))
        driver.stop()
    }
}

@MainActor
final class AllenHeathDLiveDriverTests: XCTestCase {
    func testFaderLaw() {
        XCTAssertEqual(AllenHeathDLiveDriver.wireLevel(decibels: 0), 0x6B)
        XCTAssertEqual(AllenHeathDLiveDriver.wireLevel(decibels: 10), 0x7F)
        XCTAssertEqual(AllenHeathDLiveDriver.wireLevel(decibels: nil), 0)
        XCTAssertEqual(AllenHeathDLiveDriver.wireLevel(decibels: -60), 0)
        XCTAssertEqual(AllenHeathDLiveDriver.decibels(level: 0x7F)!, 10, accuracy: 1e-9)
        XCTAssertNil(AllenHeathDLiveDriver.decibels(level: 0))
    }

    func testUsesTheSurfacePortWhenAskedAndOffsetsChannelsByStripType() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathDLive) { $0.port = 51328; $0.midiChannel = 12 }, transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 51328))
        driver.send("ip.1.level", .level(AudioTaper.unity))
        driver.send("dca.2.mute", .on(true)) // DCAs: N+4, CH 0x36 onwards
        driver.send("staux.1.mute", .on(false)) // stereo auxes: N+2, CH 0x40 onwards
        XCTAssertEqual(net.last.sent.map { [UInt8]($0) }, [
            [0xBB, 0x63, 0x00, 0xBB, 0x62, 0x17, 0xBB, 0x06, 0x6B],
            [0x9F, 0x37, 0x7F, 0x9F, 0x37, 0x00],
            [0x9D, 0x40, 0x3F, 0x9D, 0x40, 0x00]
        ])
    }

    func testReportsMutesLevelsAndNames() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathDLive), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        net.last.reply(Data([0x90, 0x04, 0x7F, 0x04, 0x00])) // input 5 muted, then the note-off
        net.last.reply(Data([0xB4, 0x63, 0x36, 0xB4, 0x62, 0x17, 0xB4, 0x06, 0x6B])) // DCA 1 at 0 dB
        net.last.reply(Data(AllenHeathDLiveDriver.sysexHeader + [0x00, 0x02, 0x04] + Array("Vox".utf8) + [0xF7]))
        XCTAssertEqual(sink.values["ip.5.mute"], .on(true))
        XCTAssertEqual(sink.values["dca.1.level"]!.level!, AudioTaper.unity, accuracy: 0.01)
        XCTAssertEqual(sink.names["ip.5"], "Vox")
        driver.stop()
    }

    func testRecallsScenesInBanksOf128() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathDLive), transport: net.factory)
        driver.start()
        driver.send("scene", .number(200))
        XCTAssertEqual(net.last.sentBytes, [0xB0, 0x00, 0x01, 0xC0, 71])
    }
}

@MainActor
final class YamahaRCPDriverTests: XCTestCase {
    func testSendsZeroBasedLevelsInHundredthsOfADecibel() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.yamahaRCP), transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 49280))
        driver.send("inch.1.level", .level(0.5))
        driver.send("inch.17.mute", .on(true))
        driver.send("st.level", .level(0))
        driver.send("scene", .number(12))
        XCTAssertEqual(net.last.sentLines, [
            "set MIXER:Current/InCh/Fader/Level 0 0 -1000",
            "set MIXER:Current/InCh/Fader/On 16 0 0",
            "set MIXER:Current/St/Fader/Level 0 0 -32768",
            "ssrecall_ex scene_a 12"
        ])
    }

    func testConnectsOnFirstAnswerAndFollowsNotifications() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.yamahaRCP) { $0.variant = "clql" }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connecting)
        XCTAssertEqual(net.last.sentLines, ["devstatus runmode"])

        net.last.reply(line: #"OK devstatus runmode "normal""#)
        XCTAssertEqual(sink.states.last, .connected)
        net.last.reply(line: #"NOTIFY set MIXER:Current/InCh/Fader/Level 2 0 0 "0.00""#)
        net.last.reply(line: "OK get MIXER:Current/DCA/Fader/On 0 0 0")
        net.last.reply(line: #"OK get MIXER:Current/InCh/Label/Name 2 0 "Lead Vox""#)
        net.last.reply(line: "ERROR get MIXER:Current/Nope 0 0")
        XCTAssertEqual(sink.values["inch.3.level"]!.level!, AudioTaper.unity, accuracy: 1e-9)
        XCTAssertEqual(sink.values["dca.1.mute"], .on(true))
        XCTAssertEqual(sink.names["inch.3"], "Lead Vox")

        driver.send("scene", .number(5))
        XCTAssertEqual(net.last.sentLines.last, "ssrecall_ex MIXER:Lib/Scene 5")
        driver.stop()
    }
}
