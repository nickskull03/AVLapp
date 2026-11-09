import XCTest
@testable import ShowKit

final class KeyPanelLineTests: XCTestCase {
    func testDigitsJoinAndWordsAreSpaced() {
        var line = ""
        for token in ["Group", "1", "Thru", "1", "2", "At", "5", ".", "5"] {
            line = KeyPanel.append(token, to: line)
        }
        XCTAssertEqual(line, "Group 1 Thru 12 At 5.5")
    }

    func testBackspaceTakesADigitOrAWord() {
        XCTAssertEqual(KeyPanel.deleteLast("Group 12"), "Group 1")
        XCTAssertEqual(KeyPanel.deleteLast("Group 1"), "Group")
        XCTAssertEqual(KeyPanel.deleteLast("Group 1 At"), "Group 1")
        XCTAssertEqual(KeyPanel.deleteLast("Group"), "")
        XCTAssertEqual(KeyPanel.deleteLast(""), "")
    }

    func testSectionWidthCountsSpans() {
        XCTAssertEqual(KeySection(id: "n", title: "Numbers", rows: PanelKey.numberPad()).columns, 3)
    }
}

@MainActor
final class KeyPanelDriverTests: XCTestCase {
    /// Every trigger and press key on a panel reaches the wire, and ids are unique.
    private func checkPanel(_ kind: DeviceKind, sent: (FakeTransport) -> Int) {
        let net = FakeNetwork()
        let driver = Drivers.make(config(kind), transport: net.factory)
        driver.start()
        guard let panel = driver.keyPanel else { return XCTFail("\(kind) has no key panel") }
        let ids = panel.keys.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(kind): duplicate key ids")
        for key in panel.keys {
            net.last.clear()
            switch key.action {
            case .trigger(let id):
                driver.send(id, .trigger)
                XCTAssertEqual(sent(net.last), 1, "\(kind): \(key.label) sent nothing")
            case .press(let id):
                driver.send(id, .press(true))
                driver.send(id, .press(false))
                XCTAssertEqual(sent(net.last), 2, "\(kind): \(key.label) didn't press and release")
            case .clear(let id?):
                driver.send(id, .trigger)
                XCTAssertEqual(sent(net.last), 1, "\(kind): \(key.label) sent nothing")
            default:
                break
            }
        }
    }

    func testEveryKeyOnEveryPanelSendsSomething() {
        checkPanel(.grandMA3) { $0.sent.count }
        checkPanel(.chamsysMagicQ) { $0.sent.count }
        checkPanel(.etcEos) { $0.sent.count }
        checkPanel(.lightingConsole) { $0.sent.count }
        XCTAssertNil(Drivers.make(config(.artNet), transport: FakeNetwork().factory).keyPanel)
    }

    func testMA3PanelSendsCommandLines() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.grandMA3), transport: net.factory)
        driver.start()
        XCTAssertEqual(driver.keyPanel?.commandLine, .local(send: "command"))
        driver.send("panel.goplus", .trigger)
        driver.send("panel.oops", .trigger)
        driver.send("command", .text("Group 1 Thru 5 At Full"))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/gma3/cmd", [.string("Go+")]),
            OSCMessage("/gma3/cmd", [.string("Oops")]),
            OSCMessage("/gma3/cmd", [.string("Group 1 Thru 5 At Full")])
        ])
    }

    func testEosKeysArePressedOnTheConsoleAndItsCommandLineComesBack() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.etcEos) { $0.user = 3 }, transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        driver.send("key.chan", .press(true))
        driver.send("key.chan", .press(false))
        var framer = OSCLengthFramer()
        let sent = net.last.sent.flatMap { framer.feed($0) }.flatMap { OSCMessage.decode($0) }
        XCTAssertEqual(sent, [
            OSCMessage("/eos/user/3/key/chan", [.float(1)]),
            OSCMessage("/eos/user/3/key/chan", [.float(0)])
        ])
        net.last.reply(OSCLengthFramer.frame(OSCMessage("/eos/out/user/3/cmd", [.string("LIVE: Chan 1 @")]).encoded()))
        XCTAssertEqual(sink.info["device.cmdline"], "LIVE: Chan 1 @")
        net.last.reply(OSCLengthFramer.frame(OSCMessage("/eos/out/cmd", [.string("")]).encoded()))
        XCTAssertNil(sink.info["device.cmdline"])
    }

    func testMagicQKeysUseTheRemoteProtocol() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.chamsysMagicQ), transport: net.factory)
        driver.start()
        driver.send("rpc.3.go", .trigger)
        driver.send("rpc.3.release", .trigger)
        driver.send("jump", .text("2 5"))
        driver.send("jump", .text("2 5.5"))
        driver.send("jump", .text("nonsense"))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/rpc", [.string("3G")]),
            OSCMessage("/rpc", [.string("3R")]),
            OSCMessage("/rpc", [.string("2,5J")]),
            OSCMessage("/rpc", [.string("2,5,5J")])
        ])
    }

    func testLightingConsolePanelSendsCommands() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.lightingConsole), transport: net.factory)
        driver.start()
        driver.send("panel.go", .trigger)
        driver.send("panel.clearall", .trigger)
        let texts = net.last.sent.compactMap { data in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
        }
        XCTAssertEqual(texts, ["Go", "ClearAll"])
    }
}
