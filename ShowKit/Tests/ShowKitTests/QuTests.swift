import XCTest
@testable import ShowKit

/// The new Qu (Qu-5/6/7): the SQ's protocol with the Qu's layout. Expected
/// bytes are the examples in the Qu-5/6/7 MIDI Protocol, as checked by the
/// Companion Qu-5D/6D/7D module's tests.
@MainActor
final class QuDriverTests: XCTestCase {
    private func bytes(_ net: FakeNetwork) -> [[UInt8]] { net.last.sent.map { [UInt8]($0) } }

    func testMutesUseTheQuLayout() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQu), transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 51325))
        driver.send("ip.1.mute", .on(true))
        driver.send("lr.mute", .on(false))
        XCTAssertEqual(bytes(net), [
            [0xB0, 0x63, 0x00, 0xB0, 0x62, 0x00, 0xB0, 0x06, 0x00, 0xB0, 0x26, 0x01],
            [0xB0, 0x63, 0x00, 0xB0, 0x62, 0x44, 0xB0, 0x06, 0x00, 0xB0, 0x26, 0x00]
        ])
    }

    func testMuteGroupOnAnotherMIDIChannel() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQu) { $0.midiChannel = 7 }, transport: net.factory)
        driver.start()
        driver.send("mg.4.mute", .on(true))
        XCTAssertEqual(bytes(net), [[0xB6, 0x63, 0x04, 0xB6, 0x62, 0x03, 0xB6, 0x06, 0x00, 0xB6, 0x26, 0x01]])
    }

    func testStereoInputsAndMastersSitWhereTheQuPutsThem() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQu), transport: net.factory)
        driver.start()
        let cases: [(ControlID, UInt8, UInt8)] = [
            ("st.2.mute", 0x00, 0x22), // ST2
            ("st.3.mute", 0x00, 0x24), // USB
            ("fxr.6.mute", 0x00, 0x41),
            ("mix.12.mute", 0x00, 0x50),
            ("fxs.4.mute", 0x00, 0x54),
            ("mtx.4.mute", 0x00, 0x58),
            ("dca.8.mute", 0x02, 0x07),
            ("st.3.level", 0x40, 0x24), // USB into LR
            ("lr.level", 0x4F, 0x00),
            ("fxs.1.level", 0x4F, 0x0D),
            ("mtx.4.level", 0x4F, 0x14),
            ("dca.1.level", 0x4F, 0x20)
        ]
        for (id, msb, lsb) in cases {
            net.last.clear()
            if id.rawValue.hasSuffix("mute") { driver.send(id, .on(true)) } else { driver.send(id, .level(0)) }
            XCTAssertEqual(Array(bytes(net).first?.prefix(6) ?? []), [0xB0, 0x63, msb, 0xB0, 0x62, lsb], id.rawValue)
        }
        let names = driver.groups.first { $0.id == "st" }?.strips.map(\.defaultName)
        XCTAssertEqual(names, ["ST1", "ST2", "USB"])
        XCTAssertNil(driver.groups.first { $0.id == "grp" }, "Qu mixes are the groups")
    }

    func testScenesUpTo300() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQu), transport: net.factory)
        driver.start()
        driver.send("scene", .number(300))
        XCTAssertEqual(bytes(net), [[0xB0, 0x00, 0x02, 0xC0, 0x2B]])
    }
}

/// The original Qu (Qu-16/24/32/Pac/SB).
@MainActor
final class QuClassicDriverTests: XCTestCase {
    private func bytes(_ net: FakeNetwork) -> [[UInt8]] { net.last.sent.map { [UInt8]($0) } }

    func testFaderLawFollowsTheTable() {
        XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: 0), 0x62)
        XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: 10), 0x7F)
        XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: -40), 0x0F)
        XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: nil), 0)
        XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: -70), 0)
        XCTAssertEqual(AllenHeathQuClassicDriver.decibels(value: 0x62)!, 0, accuracy: 0.01)
        XCTAssertEqual(AllenHeathQuClassicDriver.decibels(value: 0x3E)!, -10, accuracy: 0.01)
        XCTAssertNil(AllenHeathQuClassicDriver.decibels(value: 0))
        // Every value on the table survives a round trip.
        for (db, value) in AllenHeathQuClassicDriver.taper {
            XCTAssertEqual(AllenHeathQuClassicDriver.wireLevel(decibels: AllenHeathQuClassicDriver.decibels(value: UInt8(value))),
                           UInt8(value), "\(db) dB")
        }
    }

    func testSendsFadersMutesAndScenes() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQuClassic) { $0.midiChannel = 2 }, transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 51325))
        driver.send("ip.1.level", .level(AudioTaper.unity))
        driver.send("ip.1.mute", .on(true))
        driver.send("lr.mute", .on(false))
        driver.send("scene", .number(5))
        XCTAssertEqual(bytes(net), [
            [0xB1, 0x63, 0x20, 0xB1, 0x62, 0x17, 0xB1, 0x06, 0x62, 0xB1, 0x26, 0x07],
            [0x91, 0x20, 0x7F, 0x81, 0x20, 0x00],
            [0x91, 0x67, 0x3F, 0x81, 0x67, 0x00],
            [0xB1, 0x00, 0x00, 0xC1, 0x04]
        ])
    }

    func testModelsHaveTheirOwnStrips() {
        let qu16 = Drivers.make(config(.allenHeathQuClassic) { $0.variant = "qu16" }, transport: FakeNetwork().factory)
        XCTAssertEqual(qu16.groups.first { $0.id == "ip" }?.strips.count, 16)
        XCTAssertNil(qu16.groups.first { $0.id == "grp" })
        let qu32 = Drivers.make(config(.allenHeathQuClassic) { $0.variant = "qu32" }, transport: FakeNetwork().factory)
        XCTAssertEqual(qu32.groups.first { $0.id == "ip" }?.strips.count, 32)
        XCTAssertEqual(qu32.groups.first { $0.id == "grp" }?.strips.map(\.defaultName), ["Grp 1/2", "Grp 3/4", "Grp 5/6", "Grp 7/8"])
    }

    func testAsksForEverythingOnConnectAndReadsReplies() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.allenHeathQuClassic) { $0.variant = "qu16" }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connected)
        let sent = bytes(net).flatMap { $0 }
        let header: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, 0x00]
        XCTAssertEqual(Array(sent.prefix(12)), header + [0x10, 0x01, 0xF7]) // get system state
        XCTAssertTrue(sent.count > 12)

        net.last.reply(Data([0xB0, 0x63, 0x21, 0xB0, 0x62, 0x17, 0xB0, 0x06, 0x62, 0xB0, 0x26, 0x07])) // Ch 2 at 0 dB
        net.last.reply(Data([0x90, 0x22, 0x7F, 0x80, 0x22, 0x00])) // Ch 3 muted
        net.last.reply(Data([0x90, 0x67, 0x3F])) // LR not muted
        net.last.reply(Data(header + [0x02, 0x20] + Array("Vocal".utf8) + [0xF7])) // Ch 1's name
        XCTAssertEqual(sink.values["ip.2.level"]!.level!, AudioTaper.unity, accuracy: 0.01)
        XCTAssertEqual(sink.values["ip.3.mute"], .on(true))
        XCTAssertEqual(sink.values["lr.mute"], .on(false))
        XCTAssertEqual(sink.names["ip.1"], "Vocal")
        driver.stop()
    }
}
