import XCTest
@testable import ShowKit

final class DynamicsLayoutTests: XCTestCase {
    func testCompressorCurve() {
        // Below the threshold nothing changes; above it, 4:1.
        XCTAssertEqual(DynamicsLayout.compressed(-30, threshold: -20, ratio: 4, knee: 0, makeup: 0), -30, accuracy: 1e-9)
        XCTAssertEqual(DynamicsLayout.compressed(0, threshold: -20, ratio: 4, knee: 0, makeup: 0), -15, accuracy: 1e-9)
        XCTAssertEqual(DynamicsLayout.compressed(0, threshold: -20, ratio: .infinity, knee: 0, makeup: 3), -17, accuracy: 1e-9)
        // A soft knee meets both lines at its edges.
        XCTAssertEqual(DynamicsLayout.compressed(-25, threshold: -20, ratio: 4, knee: 10, makeup: 0), -25, accuracy: 1e-9)
        XCTAssertEqual(DynamicsLayout.compressed(-15, threshold: -20, ratio: 4, knee: 10, makeup: 0), -18.75, accuracy: 1e-9)
    }

    func testGateCurve() {
        XCTAssertEqual(DynamicsLayout.gated(-50, threshold: -40, range: 30), -80)
        XCTAssertEqual(DynamicsLayout.gated(-50, threshold: -40, range: -30), -80)
        XCTAssertEqual(DynamicsLayout.gated(-10, threshold: -40, range: 30), -10)
    }

    func testReadsRatioOptions() {
        XCTAssertEqual(DynamicsLayout.number(fromOption: "4:1"), 4)
        XCTAssertEqual(DynamicsLayout.number(fromOption: "1.5"), 1.5)
        XCTAssertEqual(DynamicsLayout.number(fromOption: "∞:1"), .infinity)
        XCTAssertNil(DynamicsLayout.number(fromOption: "Hard"))
    }

    @MainActor
    func testFindsTheControlsInEveryMixersCompressor() {
        for kind in [DeviceKind.behringerX32, .behringerWing, .demoAudio] {
            let driver = Drivers.make(config(kind), transport: FakeNetwork().factory)
            let strip = driver.groups.flatMap(\.strips).first { $0.style == .input }!
            let comp = strip.sections.first { $0.id == "comp" }!
            let layout = DynamicsLayout(section: comp)
            XCTAssertEqual(layout?.kind, .compressor, "\(kind)")
            XCTAssertNotNil(layout?.threshold, "\(kind)")
            XCTAssertNotNil(layout?.ratio, "\(kind)")
            XCTAssertNotNil(layout?.attack, "\(kind)")
            XCTAssertNotNil(layout?.release, "\(kind)")
            XCTAssertNotNil(layout?.on, "\(kind)")
            let gate = strip.sections.first { $0.id == "gate" }.flatMap(DynamicsLayout.init(section:))
            XCTAssertEqual(gate?.kind, .gate, "\(kind)")
            XCTAssertNotNil(gate?.range, "\(kind)")
            // EQ and sends aren't dynamics.
            for section in strip.sections where section.id == "eq" || section.id == "sends" {
                XCTAssertNil(DynamicsLayout(section: section), "\(kind) \(section.id)")
            }
        }
    }
}

@MainActor
final class DemoDriverTests: XCTestCase {
    func testDemoConsolesNeedNoAddress() {
        XCTAssertEqual(DeviceConfig(kind: .demoAudio).host, "demo")
        XCTAssertEqual(DeviceConfig(kind: .demoLighting).host, "demo")
        XCTAssertEqual(DeviceKind.demoAudio.domain, .audio)
        XCTAssertEqual(DeviceKind.demoLighting.domain, .lighting)
    }

    func testDemoMixerConnectsAndPlaysBackChanges() {
        let net = FakeNetwork()
        let driver = Drivers.make(config(.demoAudio), transport: net.factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertTrue(net.transports.isEmpty, "the demo never opens a connection")
        XCTAssertEqual(sink.states.last, .connected)
        XCTAssertTrue(sink.synced)
        XCTAssertEqual(sink.values["ch.1.level"], .level(AudioTaper.unity))
        XCTAssertEqual(sink.values["ch.1.mute"], .on(false))
        driver.send("ch.1.mute", .on(true))
        XCTAssertEqual(sink.values["ch.1.mute"], .on(true))
        driver.send("ch.1.comp.ratio", .number(8))
        XCTAssertEqual(sink.values["ch.1.comp.ratio"], .number(8))
        driver.stop()
    }

    func testDemoLightingStepsThroughCues() {
        let driver = Drivers.make(config(.demoLighting), transport: FakeNetwork().factory)
        let sink = SinkRecorder(driver)
        driver.start()
        XCTAssertEqual(sink.names["fader.1"], "Front wash")
        XCTAssertNotNil(driver.keyPanel)
        driver.send("fader.2.go", .trigger)
        XCTAssertEqual(sink.info["fader.2.cue"], "1 Preset")
        XCTAssertEqual(sink.info["fader.2.next"], "2 Walk in")
        XCTAssertEqual(sink.info["fader.2.active"], "1")
        driver.send("fader.2.go", .trigger)
        XCTAssertEqual(sink.info["fader.2.cue"], "2 Walk in")
        driver.send("fader.2.off", .trigger)
        XCTAssertNil(sink.info["fader.2.cue"])
        driver.send("command", .text("Fader 3 At 50"))
        XCTAssertEqual(sink.values["fader.3.level"], .level(0.5))
    }
}
