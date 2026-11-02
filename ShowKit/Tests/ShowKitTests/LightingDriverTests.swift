import XCTest
@testable import ShowKit

@MainActor
final class GrandMA3DriverTests: XCTestCase {
    func testSendsFadersKeysAndCommandsUnderThePrefix() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3) { $0.page = 2 }, transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 8000, listenPort: 8001))
        driver.send("exec.201.level", .level(0.5))
        driver.send("exec.201.go", .trigger)
        driver.send("exec.202.key", .press(true))
        driver.send("exec.202.key", .press(false))
        driver.send("command", .text(" Go+ Sequence 3 "))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/gma3/Page2/Fader201", [.float(50)]),
            OSCMessage("/gma3/cmd", [.string("Go+ Page 2.201")]),
            OSCMessage("/gma3/Page2/Key202", [.int(1)]),
            OSCMessage("/gma3/Page2/Key202", [.int(0)]),
            OSCMessage("/gma3/cmd", [.string("Go+ Sequence 3")])
        ])
    }

    func testEmptyPrefixAndCustomRange() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3) { $0.oscPrefix = ""; $0.faderRange = 1 }, transport: net.factory)
        driver.start()
        driver.send("exec.205.level", .level(1))
        XCTAssertEqual(net.last.sentOSC, [OSCMessage("/Page1/Fader205", [.float(1)])])
    }

    func testIsOnlySendingUntilFeedbackArrivesAndFollowsTheCurrentPage() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .sending)
        XCTAssertTrue(sink.synced)

        net.last.reply(OSCMessage("/gma3/Page1/Fader203", [.string("FaderMaster"), .float(40)]))
        net.last.reply(OSCMessage("/gma3/Page2/Fader204", [.float(100)]))
        XCTAssertEqual(sink.states.last, .connected)
        XCTAssertEqual(sink.values["exec.203.level"], .level(0.4))
        XCTAssertNil(sink.values["exec.204.level"]) // another page

        driver.send("page", .number(2))
        XCTAssertEqual(sink.values["exec.204.level"], .level(1))
        XCTAssertEqual(sink.values["exec.203.level"], .level(0))
    }
}

@MainActor
final class MagicQDriverTests: XCTestCase {
    func testSendsPlaybackLevelsAndButtons() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.chamsysMagicQ), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 8000, listenPort: 9000))
        XCTAssertEqual(driver.groups[0].strips.count, 10)
        driver.send("pb.3.level", .level(0.25))
        driver.send("pb.3.go", .trigger)
        driver.send("pb.3.flash", .press(true))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/pb/3", [.float(0.25)]),
            OSCMessage("/pb/3/go", [.int(1)]),
            OSCMessage("/pb/3/flash", [.int(1)])
        ])
        net.last.reply(OSCMessage("/pb/4", [.int(50)]))
        XCTAssertEqual(sink.values["pb.4.level"], .level(0.5))
    }
}

@MainActor
final class EosDriverTests: XCTestCase {
    private func sent(_ transport: FakeTransport) -> [OSCMessage] {
        var framer = OSCLengthFramer()
        return transport.sent.flatMap { framer.feed($0) }.flatMap { OSCMessage.decode($0) }
    }

    func testConfiguresItsFaderBankAndSubscribesOnConnect() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.etcEos) { $0.count = 8; $0.user = 3 }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertEqual(net.last.spec, .tcp(host: "10.0.0.5", port: 3032))
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connected)
        XCTAssertEqual(sent(net.last), [
            OSCMessage("/eos/user/3/fader/1/config/8"),
            OSCMessage("/eos/subscribe", [.int(1)])
        ])
        driver.stop()
    }

    func testSendsFramedFaderMovesAndReadsFeedback() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.etcEos) { $0.user = 0 }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        driver.send("fader.2.level", .level(0.6))
        driver.send("command", .text("Chan 1 At Full"))
        XCTAssertEqual(sent(net.last), [
            OSCMessage("/eos/fader/1/2", [.float(0.6)]),
            OSCMessage("/eos/cmd", [.string("Chan 1 At Full#")])
        ])
        let reply = OSCLengthFramer.frame(OSCMessage("/eos/out/fader/1/2", [.float(0.3)]).encoded())
            + OSCLengthFramer.frame(OSCMessage("/eos/out/fader/1/2/name", [.string("Front Wash")]).encoded())
        net.last.reply(reply)
        XCTAssertEqual(sink.values["fader.2.level"]!.level!, 0.3, accuracy: 1e-6)
        XCTAssertEqual(sink.names["fader.2"], "Front Wash")
    }
}

@MainActor
final class ArtNetDriverTests: XCTestCase {
    func testScalesChannelsByMasterAndHonoursBlackout() {
        let net = FakeNetwork()
        let driver = ArtNetDriver(config: config(.artNet) { $0.firstNumber = 10; $0.count = 4; $0.universe = 1 }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 6454, listenPort: nil))
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .sending)
        XCTAssertEqual(sink.values[ArtNetDriver.masterID], .level(1)) // the app owns the state, so it reports it

        driver.send("dmx.10.level", .level(1))
        driver.send("dmx.11.level", .level(0.5))
        XCTAssertEqual(Array(driver.slots[9...11]), [255, 128, 0])
        driver.send(ArtNetDriver.masterID, .level(0.5))
        XCTAssertEqual(Array(driver.slots[9...10]), [128, 64])
        driver.send(ArtNetDriver.blackoutID, .on(true))
        XCTAssertEqual(driver.slots.max(), 0)

        let last = [UInt8](net.last.sent.last!)
        XCTAssertEqual(last[14], 1) // universe 1
        XCTAssertEqual(last.count, 18 + 14) // channels 1–13 in use, padded to 14
        driver.stop()
    }
}
