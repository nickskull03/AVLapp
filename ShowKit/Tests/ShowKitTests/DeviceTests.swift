import XCTest
@testable import ShowKit

@MainActor
final class DeviceTests: XCTestCase {
    private func connectedX32() -> (Device, FakeNetwork) {
        let net = FakeNetwork()
        let device = Device(config: config(.behringerX32), transport: net.factory)
        device.connect()
        net.last.becomeReady()
        net.last.reply(OSCMessage("/xinfo"))
        return (device, net)
    }

    func testStaysLockedUntilTheConsoleHasBeenRead() {
        let (device, _) = connectedX32()
        XCTAssertEqual(device.state, .connected)
        XCTAssertFalse(device.isLive) // still reading
    }

    func testFollowsTheConsoleUntilAFingerIsOnTheFader() {
        let (device, net) = connectedX32()
        net.last.reply(OSCMessage("/ch/01/mix/fader", [.float(0.5)]))
        XCTAssertEqual(device.control("ch/01.level").value, .level(0.5))

        device.touch("ch/01.level", true)
        net.last.reply(OSCMessage("/ch/01/mix/fader", [.float(0.9)]))
        XCTAssertEqual(device.control("ch/01.level").value, .level(0.5)) // ignored while touched
    }

    func testSendsTheFirstMoveAtOnceAndIgnoresEchoesRightAfter() {
        let (device, net) = connectedX32()
        net.last.clear()
        device.touch("ch/02.level", true)
        device.setLevel("ch/02.level", 0.6)
        XCTAssertEqual(net.last.sentOSC.last, OSCMessage("/ch/02/mix/fader", [.float(0.6)]))
        device.touch("ch/02.level", false)
        // An old echo arriving just after release doesn't pull the fader back.
        net.last.reply(OSCMessage("/ch/02/mix/fader", [.float(0.2)]))
        XCTAssertEqual(device.control("ch/02.level").value, .level(0.6))
    }

    func testQueuesFastMovesAndSendsTheFinalValueOnRelease() {
        let (device, net) = connectedX32()
        net.last.clear()
        device.touch("ch/03.level", true)
        device.setLevel("ch/03.level", 0.1)
        device.setLevel("ch/03.level", 0.2) // within the send interval: queued
        device.setLevel("ch/03.level", 0.3)
        XCTAssertEqual(net.last.sentOSC.count, 1)
        device.touch("ch/03.level", false)
        XCTAssertEqual(net.last.sentOSC.map(\.arguments), [[.float(0.1)], [.float(0.3)]])
    }

    func testReleasingTouchesSendsTheFinalValueAndFollowsTheDeskAgain() {
        let (device, net) = connectedX32()
        net.last.clear()
        device.touch("ch/05.level", true)
        device.setLevel("ch/05.level", 0.4)
        device.setLevel("ch/05.level", 0.45) // queued
        device.releaseTouches()
        XCTAssertFalse(device.control("ch/05.level").isTouched)
        XCTAssertEqual(net.last.sentOSC.last, OSCMessage("/ch/05/mix/fader", [.float(0.45)]))
    }

    func testSwitchesAreSentAsExplicitStates() {
        let (device, net) = connectedX32()
        net.last.clear()
        device.set("ch/04.mute", on: true)
        device.set("ch/04.mute", on: true)
        XCTAssertEqual(net.last.sentOSC, [
            OSCMessage("/ch/04/mix/on", [.int(0)]),
            OSCMessage("/ch/04/mix/on", [.int(0)])
        ])
        XCTAssertEqual(device.control("ch/04.mute").value, .on(true))
    }

    func testDisconnectStopsAndForgetsTheLink() {
        let (device, net) = connectedX32()
        device.disconnect()
        XCTAssertFalse(net.last.isOpen)
        XCTAssertEqual(device.state, .disconnected)
        XCTAssertFalse(device.isActive)
    }
}

@MainActor
final class ShowTests: XCTestCase {
    func testRunsCuesAcrossDevicesAndSkipsOnesThatArentLive() {
        let net = FakeNetwork()
        let show = Show(fileURL: nil, transport: net.factory)
        let mixer = show.addDevice(config(.behringerX32))
        let lights = show.addDevice(config(.artNet))
        lights.connect()
        let lightsTransport = net.transports.last!
        lightsTransport.becomeReady()
        XCTAssertTrue(lights.isLive)

        let cue = Cue(name: "Speech", steps: [
            CueStep(deviceID: lights.id, control: "dmx.1.level", value: .level(1), summary: "Podium special full"),
            CueStep(deviceID: mixer.id, control: "ch/01.mute", value: .on(false), summary: "Lectern mic on")
        ])
        show.saveCue(cue)
        let skipped = show.run(cue)
        XCTAssertEqual(skipped.map(\.summary), ["Lectern mic on"]) // the mixer isn't connected
        XCTAssertEqual(lights.control("dmx.1.level").value, .level(1))
    }

    func testSavesAndReloadsDevicesAndCues() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("show-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let net = FakeNetwork()
        let show = Show(fileURL: url, transport: net.factory)
        let device = show.addDevice(config(.yamahaRCP) { $0.variant = "dm3"; $0.name = "FOH" })
        show.saveCue(Cue(name: "Walk-in", steps: [
            CueStep(deviceID: device.id, control: "st.level", value: .level(0.75), summary: "Stereo to 0 dB")
        ], needsConfirmation: true))

        let reloaded = Show(fileURL: url, transport: net.factory)
        XCTAssertEqual(reloaded.devices.map(\.config), [device.config])
        XCTAssertEqual(reloaded.cues, show.cues)
    }

    func testOpensConfigsSavedWithMissingFields() throws {
        let json = #"{"id":"6B1D7C5A-3F22-4E43-9C60-0D7C9F0B1E11","kind":"grandMA3","host":"10.1.1.1"}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.host, "10.1.1.1")
        XCTAssertEqual(config.port, 8000)
        XCTAssertEqual(config.firstNumber, 1) // grandMA3 columns start at x01
    }

    func testReordersLikeAList() {
        var items = ["a", "b", "c", "d"]
        items.moveItems(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(items, ["b", "c", "a", "d"])
        items.moveItems(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(items, ["d", "b", "c", "a"])
    }
}
