import XCTest
@testable import ShowKit

final class EQMathTests: XCTestCase {
    func testAPeakHasItsGainAtItsCentreAndNoneFarAway() {
        XCTAssertEqual(EQMath.response(shape: .peak, center: 1000, gain: 6, q: 1, at: 1000), 6, accuracy: 0.01)
        XCTAssertEqual(EQMath.response(shape: .peak, center: 1000, gain: -9, q: 1, at: 1000), -9, accuracy: 0.01)
        XCTAssertEqual(EQMath.response(shape: .peak, center: 1000, gain: 6, q: 4, at: 20), 0, accuracy: 0.05)
    }

    func testShelvesAndCuts() {
        XCTAssertEqual(EQMath.response(shape: .lowShelf, center: 200, gain: 6, q: 0.707, at: 20), 6, accuracy: 0.2)
        XCTAssertEqual(EQMath.response(shape: .lowShelf, center: 200, gain: 6, q: 0.707, at: 10000), 0, accuracy: 0.1)
        XCTAssertEqual(EQMath.response(shape: .highShelf, center: 5000, gain: -6, q: 0.707, at: 19000), -6, accuracy: 0.5)
        XCTAssertEqual(EQMath.response(shape: .lowCut, center: 100, gain: 0, q: 0.707, at: 100), -3, accuracy: 0.1)
        XCTAssertLessThan(EQMath.response(shape: .lowCut, center: 100, gain: 0, q: 0.707, at: 25), -20)
        XCTAssertEqual(EQMath.response(shape: .highCut, center: 8000, gain: 0, q: 0.707, at: 100), 0, accuracy: 0.05)
    }

    func testOctavesAndPositions() {
        XCTAssertEqual(EQMath.q(octaves: 1), 1.414, accuracy: 0.001)
        XCTAssertEqual(EQMath.position(frequency: 20), 0, accuracy: 1e-9)
        XCTAssertEqual(EQMath.position(frequency: 20000), 1, accuracy: 1e-9)
        XCTAssertEqual(EQMath.frequency(position: EQMath.position(frequency: 440)), 440, accuracy: 1e-6)
        XCTAssertEqual(EQMath.frequencies(count: 3).map { $0.rounded() }, [20, 632, 20000])
    }
}

@MainActor
final class EQLayoutTests: XCTestCase {
    func testMixersDescribeTheirEQBands() {
        let net = FakeNetwork()
        let x32 = Drivers.make(config(.behringerX32), transport: net.factory)
        let input = x32.groups[0].strips[0].sections.first { $0.id == "eq" }?.eq
        XCTAssertEqual(input?.bands.count, 4)
        XCTAssertEqual(input?.bands[0].frequency, "ch/01.eq.1.freq")
        XCTAssertEqual(input?.bands[0].shapes.count, 6)
        let bus = x32.groups.first { $0.id == "bus" }!.strips[0].sections.first { $0.id == "eq" }?.eq
        XCTAssertEqual(bus?.bands.count, 6)

        let dlive = Drivers.make(config(.allenHeathDLive), transport: net.factory)
        let dliveEQ = dlive.groups[0].strips[0].sections.first { $0.id == "eq" }?.eq
        XCTAssertEqual(dliveEQ?.bands.count, 4)
        XCTAssertEqual(dliveEQ?.bands[0].qIsOctaves, true)
    }

    func testX32SendsBandTypesAndBusSends() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.behringerX32), transport: net.factory)
        driver.start()
        driver.send("ch/01.eq.2.type", .number(4))
        driver.send("ch/01.send.12", .level(AudioTaper.unity))
        driver.send("ch/01.gate.mode", .number(3))
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/01/eq/2/type", [.int(4)]),
            OSCMessage("/ch/01/mix/12/level", [.float(0.75)]),
            OSCMessage("/ch/01/gate/mode", [.int(3)])
        ])
    }
}

@MainActor
final class CustomLayerTests: XCTestCase {
    func testLayerHoldsStripsFromAnyDeviceAndIsSaved() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let net = FakeNetwork()
        let show = Show(fileURL: url, transport: net.factory)
        let mixer = show.addDevice(config(.behringerX32))
        let lights = show.addDevice(config(.grandMA3))
        show.addToLayer(LayerEntry(deviceID: lights.id, stripID: "col.1"))
        show.addToLayer(LayerEntry(deviceID: mixer.id, stripID: "ch/01"))
        show.addToLayer(LayerEntry(deviceID: mixer.id, stripID: "ch/01")) // already there
        show.addToLayer(LayerEntry(deviceID: mixer.id, stripID: "nope")) // no such strip: kept, not shown
        XCTAssertEqual(show.layer.count, 3)
        XCTAssertEqual(show.layerStrips.map(\.strip.id), ["col.1", "ch/01"])

        show.moveLayer(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(show.layerStrips.map(\.strip.id), ["ch/01", "col.1"])

        let reloaded = Show(fileURL: url, transport: net.factory)
        XCTAssertEqual(reloaded.layer, show.layer)

        show.removeDevice(mixer.id)
        XCTAssertEqual(show.layer, [LayerEntry(deviceID: lights.id, stripID: "col.1")])
    }
}

@MainActor
final class LightingConsoleSequenceTests: XCTestCase {
    func testEverySequenceGetsAStripThatWorksFromAnyPage() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.lightingConsole), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        let statuses: [[String: Any]] = [["id": 7, "level": 40, "flash": false, "run": ["cue": 2], "next": 3]]
        let playback: [String: Any] = ["page": 3, "grandMaster": 100, "blackout": false, "sequences": statuses]
        let sequences: [[String: Any]] = [["id": 7, "name": "Chase", "cues": [[String: Any]]()], ["id": 2, "name": "Wash", "cues": [[String: Any]]()]]
        let show: [String: Any] = ["faders": [[String: Any]](), "sequences": sequences]
        let state: [String: Any] = ["type": "state", "playback": playback, "show": show]
        net.last.reply(try! JSONSerialization.data(withJSONObject: state))

        XCTAssertEqual(sink.layoutChanges, 1)
        XCTAssertEqual(driver.groups.map(\.id), ["faders", "sequences", "master"])
        XCTAssertEqual(driver.groups[1].strips.map(\.id), ["seq.2", "seq.7"])
        XCTAssertEqual(sink.names["seq.7"], "Chase")
        XCTAssertEqual(sink.values["seq.7.level"], .level(0.4))
        XCTAssertEqual(sink.info["seq.7.cue"], "2")

        net.last.clear()
        driver.send("seq.7.level", .level(1))
        driver.send("seq.7.go", .trigger)
        driver.send("seq.7.goto", .text("5"))
        let sent = net.last.sent.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["text"] as? String }
        XCTAssertEqual(sent, ["Sequence 7 At 100", "Go Sequence 7", "Goto Cue 5 Sequence 7"])
    }
}
