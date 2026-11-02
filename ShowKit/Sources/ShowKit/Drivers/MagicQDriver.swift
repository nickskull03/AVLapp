import Foundation

/// ChamSys MagicQ over OSC/UDP. `/pb/<n>` sets playback n's level (0–1);
/// `/pb/<n>/go`, `/pb/<n>/stop` and `/pb/<n>/flash` work its buttons. MagicQ's
/// built-in OSC covers playbacks 1–10. With an OSC TX port set, MagicQ
/// reports playback levels back.
@MainActor
final class MagicQDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = []
    let traits: DriverTraits

    private let transport: Transport
    private var heard = false

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        traits = DriverTraits(reportsChanges: config.feedbackPort != 0, readsNames: false)
        let listen: UInt16? = config.feedbackPort == 0 ? nil : config.feedbackPort16
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: listen))
        let first = max(1, min(10, config.firstNumber))
        let last = max(first, min(10, first + max(1, config.count) - 1))
        groups = [StripGroup(id: "pb", title: "Playbacks", strips: (first...last).map { n in
            Strip(
                id: "pb.\(n)", name: "PB \(n)", style: .playback,
                fader: ControlDescriptor(ControlID("pb.\(n).level"), "Fader", .fader(.percent)),
                buttons: [
                    ControlDescriptor(ControlID("pb.\(n).go"), "Go", .trigger),
                    ControlDescriptor(ControlID("pb.\(n).stop"), "Stop", .trigger),
                    ControlDescriptor(ControlID("pb.\(n).flash"), "Flash", .momentary)
                ]
            )
        })]
        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        heard = false
        transport.open()
    }

    func stop() {
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, let n = Int(parts[1]) else { return }
        switch (parts[2], value) {
        case ("level", .level(let position)):
            transport.send(OSCMessage("/pb/\(n)", [.float(Float(clamp01(position)))]).encoded())
        case ("go", .trigger):
            transport.send(OSCMessage("/pb/\(n)/go", [.int(1)]).encoded())
        case ("stop", .trigger):
            transport.send(OSCMessage("/pb/\(n)/stop", [.int(1)]).encoded())
        case ("flash", .press(let down)):
            transport.send(OSCMessage("/pb/\(n)/flash", [.int(down ? 1 : 0)]).encoded())
        default:
            break
        }
    }

    private func transportState(_ state: TransportState) {
        if state == .ready {
            sink.state(heard ? .connected : .sending)
            sink.synced()
        } else {
            sink.state(state.linkState)
        }
    }

    private func receive(_ data: Data) {
        if !heard {
            heard = true
            sink.state(.connected)
        }
        for message in OSCMessage.decode(data) {
            let parts = message.address.split(separator: "/")
            guard parts.count == 2, parts[0] == "pb", let n = Int(parts[1]),
                  let value = message.arguments.first?.number else { continue }
            // Ints are 0–100, floats 0–1.
            let level: Double
            if case .int = message.arguments.first { level = value / 100 } else { level = value }
            sink.value(ControlID("pb.\(n).level"), .level(clamp01(level)))
        }
    }
}
