import XCTest
@testable import ShowKit

@MainActor
final class WingDriverTests: XCTestCase {
    func testSendsEnumsAsTheWingExpects() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerWing), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        driver.send("ch.2.eq.l.type", .number(1))
        driver.send("ch.2.comp.ratio", .number(5))
        driver.send("ch.2.comp.knee", .number(3))
        driver.send("ch.2.eq.2.freq", .level(1))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/2/eq/STD/leq", [.string("SHV")]),
            OSCMessage("/ch/2/dyn/COMP/ratio", [.float(2)]),
            OSCMessage("/ch/2/dyn/COMP/knee", [.int(3)]),
            OSCMessage("/ch/2/eq/STD/2f", [.float(20000)])
        ])
        net.last.reply(OSCMessage("/ch/2/eq/STD/heq", [.string("SHV")]))
        net.last.reply(OSCMessage("/ch/2/dyn/COMP/ratio", [.string("4.0"), .float(0.5), .float(4)]))
        XCTAssertEqual(sink.values["ch.2.eq.h.type"], .number(1))
        XCTAssertEqual(sink.values["ch.2.comp.ratio"], .number(9))

        let eq = driver.groups[0].strips[1].sections.first { $0.id == "eq" }?.eq
        XCTAssertEqual(eq?.bands.map(\.label), ["L", "1", "2", "3", "4", "H"])
        XCTAssertEqual(eq?.bands.first?.shapes, [.peak, .lowShelf])
        driver.stop()
    }

    func testSubscribesAndSendsInRealUnits() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerWing), transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .udp(host: "10.0.0.5", port: 2223, listenPort: nil))
        net.last.becomeReady()
        XCTAssertEqual(net.last.sentOSC.map(\.address), ["/*S", "/main/1/fdr"])

        net.last.clear()
        driver.send("ch.3.level", .level(AudioTaper.unity))
        driver.send("ch.3.mute", .on(true))
        driver.send("ch.3.gain", .level(1))
        driver.send("main.1.level", .level(0))
        driver.send("scene", .number(4))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/3/fdr", [.float(0)]),
            OSCMessage("/ch/3/mute", [.int(1)]),
            OSCMessage("/ch/3/in/set/$g", [.float(45.5)]),
            OSCMessage("/main/1/fdr", [.float(-144)]),
            OSCMessage("/$ctl/lib/$actionidx", [.int(4)]),
            OSCMessage("/$ctl/lib/$action", [.string("GO")])
        ])
        driver.stop()
    }

    func testReadsTheWingsReplies() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerWing), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.reply(OSCMessage("/ch/3/fdr", [.string("-10.0"), .float(0.5), .float(-10)]))
        net.last.reply(OSCMessage("/ch/4/fdr", [.string("-oo"), .float(0), .float(-144)]))
        net.last.reply(OSCMessage("/ch/3/mute", [.string("ON"), .float(1), .int(1)]))
        net.last.reply(OSCMessage("/ch/3/name", [.string("Vox")]))
        net.last.reply(OSCMessage("/ch/3/flt/lcf", [.string("80"), .float(0.3), .float(80)]))
        XCTAssertEqual(sink.states.last, .connected)
        XCTAssertEqual(sink.values["ch.3.level"]!.level!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sink.values["ch.4.level"], .level(0))
        XCTAssertEqual(sink.values["ch.3.mute"], .on(true))
        XCTAssertEqual(sink.names["ch.3"], "Vox")
        XCTAssertEqual(sink.values["ch.3.lc.freq"]!.level!, WingDriver.lowCutSpec.position(for: 80), accuracy: 1e-9)
        driver.stop()
    }

    func testReadsProcessingWhenADetailOpens() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerWing), transport: net.factory)
        driver.start()
        driver.detailOpened("ch.7")
        let queried = Set(net.last.sentOSC.map(\.address))
        XCTAssertTrue(queried.isSuperset(of: ["/ch/7/flt/lc", "/ch/7/flt/lcf", "/ch/7/eq/on", "/ch/7/gate/on", "/ch/7/dyn/on",
                                             "/ch/7/eq/STD/1f", "/ch/7/eq/STD/heq", "/ch/7/gate/GATE/thr", "/ch/7/dyn/COMP/ratio",
                                             "/ch/7/send/16/lvl", "/ch/7/in/set/trim"]))
        XCTAssertTrue(queried.allSatisfy { $0.hasPrefix("/ch/7/") })
        XCTAssertEqual(driver.groups.map(\.strips.count), [40, 8, 16, 8, 16, 4, 8])
    }
}

@MainActor
final class LightingConsoleDriverTests: XCTestCase {
    private func commands(_ transport: FakeTransport) -> [String] {
        transport.sent.compactMap { data in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
        }
    }

    private func reply(_ transport: FakeTransport, _ object: [String: Any]) {
        transport.reply(try! JSONSerialization.data(withJSONObject: object))
    }

    func testSendsCommandLines() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.lightingConsole), transport: net.factory)
        driver.start()
        XCTAssertEqual(net.last.spec, .webSocket(url: "ws://10.0.0.5:8080/ws"))
        driver.send("fader.3.level", .level(0.5))
        driver.send("master.level", .level(0.8))
        driver.send("master.blackout", .on(true))
        driver.send("page", .number(2))
        XCTAssertEqual(commands(net.last), ["Fader 3 At 50", "Master At 80", "Blackout", "Page 2"])
        let first = try! JSONSerialization.jsonObject(with: net.last.sent[0]) as! [String: Any]
        XCTAssertEqual(first["type"] as? String, "command")
        XCTAssertEqual(first["id"] as? Int, 1)
    }

    func testFollowsTheConsolesStateAndPage() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.lightingConsole), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        net.last.becomeReady()
        XCTAssertEqual(sink.states.last, .connected)
        XCTAssertFalse(sink.synced)

        let status: [String: Any] = ["id": 5, "level": 75, "flash": false, "run": ["cue": 3], "next": 4]
        let playback: [String: Any] = ["page": 2, "grandMaster": 80, "blackout": true, "sequences": [status]]
        let cues: [[String: Any]] = [["number": 3, "name": "Verse"], ["number": 4, "name": ""]]
        let sequence: [String: Any] = ["id": 5, "name": "Wash", "cues": cues]
        let show: [String: Any] = ["faders": [["page": 2, "fader": 1, "sequence": 5]], "sequences": [sequence]]
        reply(net.last, ["type": "state", "playback": playback, "show": show])
        XCTAssertTrue(sink.synced)
        XCTAssertEqual(sink.names["fader.1"], "Wash")
        XCTAssertEqual(sink.names["fader.2"], "")
        XCTAssertEqual(sink.values["fader.1.level"], .level(0.75))
        XCTAssertEqual(sink.info["fader.1.cue"], "3 Verse")
        XCTAssertEqual(sink.info["fader.1.next"], "4")
        XCTAssertEqual(sink.info["fader.1.active"], "1")
        XCTAssertEqual(sink.values["master.level"], .level(0.8))
        XCTAssertEqual(sink.values["master.blackout"], .on(true))

        // Page 2 is up, so commands name page 2's faders.
        net.last.clear()
        driver.send("fader.1.go", .trigger)
        driver.send("fader.1.cuefade", .text("3 2"))
        driver.send("fader.1.goto", .text("4"))
        driver.send("fader.1.flash", .press(true))
        driver.send("fader.1.store", .text("6"))
        XCTAssertEqual(commands(net.last), ["Go Fader 2.1", "Cue 3 Fader 2.1 Fade 2", "Goto Cue 4 Fader 2.1",
                                            "Flash Fader 2.1 On", "Store Cue 6 Fader 2.1"])
    }

    func testShowsTheConsolesErrors() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.lightingConsole), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        let failed: [String: Any] = ["type": "result", "id": 1, "ok": false, "message": "Show mode on: unlock to edit"]
        reply(net.last, failed)
        XCTAssertEqual(sink.info["device.message"], "Show mode on: unlock to edit")
        let done: [String: Any] = ["type": "result", "id": 2, "ok": true, "message": "Done"]
        reply(net.last, done)
        XCTAssertNil(sink.info["device.message"])
    }
}
