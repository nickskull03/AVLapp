import Foundation
@testable import ShowKit

/// Stands in for the network: records what a driver sends, and lets a test
/// play the console's side.
@MainActor
final class FakeTransport: Transport {
    let spec: TransportSpec
    var onState: (TransportState) -> Void = { _ in }
    var onReceive: (Data) -> Void = { _ in }
    var sent: [Data] = []
    var isOpen = false

    init(spec: TransportSpec) {
        self.spec = spec
    }

    func open() {
        isOpen = true
        onState(.opening)
    }

    func close() {
        isOpen = false
        onState(.idle)
    }

    func send(_ data: Data) {
        sent.append(data)
    }

    // Console side

    func becomeReady() {
        onState(.ready)
    }

    func reply(_ data: Data) {
        onReceive(data)
    }

    func reply(_ message: OSCMessage) {
        onReceive(message.encoded())
    }

    func reply(line: String) {
        onReceive(Data((line + "\n").utf8))
    }

    /// Everything sent so far, decoded as OSC (one datagram each).
    var sentOSC: [OSCMessage] {
        sent.flatMap { OSCMessage.decode($0) }
    }

    var sentBytes: [UInt8] {
        sent.flatMap { [UInt8]($0) }
    }

    var sentLines: [String] {
        sent.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
    }

    func clear() {
        sent.removeAll()
    }
}

@MainActor
final class FakeNetwork {
    var transports: [FakeTransport] = []

    var last: FakeTransport { transports.last! }

    lazy var factory: TransportFactory = { [unowned self] spec in
        let transport = FakeTransport(spec: spec)
        self.transports.append(transport)
        return transport
    }
}

/// Captures what a driver reports.
@MainActor
final class SinkRecorder {
    var states: [LinkState] = []
    var values: [ControlID: ControlValue] = [:]
    var names: [String: String] = [:]
    var synced = false

    init(_ driver: ConsoleDriver) {
        driver.sink.state = { [unowned self] in self.states.append($0) }
        driver.sink.value = { [unowned self] in self.values[$0] = $1 }
        driver.sink.name = { [unowned self] in self.names[$0] = $1 }
        driver.sink.synced = { [unowned self] in self.synced = true }
    }
}

func config(_ kind: DeviceKind, _ change: (inout DeviceConfig) -> Void = { _ in }) -> DeviceConfig {
    var config = DeviceConfig(kind: kind, host: "10.0.0.5")
    change(&config)
    return config
}
