import Foundation

/// ETC Eos family over OSC on TCP 3032 (OSC 1.0 framing: each packet
/// preceded by its length). The app creates OSC fader bank 1 with
/// `/eos/fader/1/config/<count>`, drives it with `/eos/fader/1/<n>` (0–1), and
/// subscribes with `/eos/subscribe` so Eos reports levels and names back as
/// `/eos/out/fader/1/<n>`. Commands go to the app's own OSC user, so they
/// don't land on the main desk's command line.
@MainActor
final class EosDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("go", "Go", .trigger),
        ControlDescriptor("stopback", "Stop/Back", .trigger),
        ControlDescriptor("pageup", "Fader page +", .trigger),
        ControlDescriptor("pagedown", "Fader page −", .trigger),
        ControlDescriptor("command", "Command", .command)
    ]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    private let transport: Transport
    private let count: Int
    private let base: String
    private var framer = OSCLengthFramer()
    private let ping = Ticker()
    private var lastHeard = ContinuousClock.now

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))
        let count = max(1, min(100, config.count))
        self.count = count
        base = config.user > 0 ? "/eos/user/\(config.user)" : "/eos"
        groups = [StripGroup(id: "fader", title: "Faders", strips: (1...count).map { n in
            Strip(
                id: "fader.\(n)", name: "Fader \(n)", style: .playback,
                fader: ControlDescriptor(ControlID("fader.\(n).level"), "Fader", .fader(.percent)),
                buttons: [
                    ControlDescriptor(ControlID("fader.\(n).fire"), "Fire", .trigger),
                    ControlDescriptor(ControlID("fader.\(n).stop"), "Stop", .trigger)
                ]
            )
        })]
        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        framer = OSCLengthFramer()
        transport.open()
    }

    func stop() {
        ping.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id.rawValue, value) {
        case ("go", .trigger): osc("\(base)/key/go_0", [.float(1)]); osc("\(base)/key/go_0", [.float(0)]); return
        case ("stopback", .trigger): osc("\(base)/key/stop_back", [.float(1)]); osc("\(base)/key/stop_back", [.float(0)]); return
        case ("pageup", .trigger): osc("\(base)/fader/1/page/1"); return
        case ("pagedown", .trigger): osc("\(base)/fader/1/page/-1"); return
        case ("command", .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { osc("\(base)/cmd", [.string(trimmed + "#")]) } // # = Enter
            return
        default:
            break
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, let n = Int(parts[1]) else { return }
        switch (parts[2], value) {
        case ("level", .level(let position)):
            osc("\(base)/fader/1/\(n)", [.float(Float(clamp01(position)))])
        case ("fire", .trigger):
            osc("\(base)/fader/1/\(n)/fire")
        case ("stop", .trigger):
            osc("\(base)/fader/1/\(n)/stop")
        default:
            break
        }
    }

    // MARK: Private

    private func osc(_ address: String, _ arguments: [OSCArgument] = []) {
        transport.send(OSCLengthFramer.frame(OSCMessage(address, arguments).encoded()))
    }

    private func transportState(_ state: TransportState) {
        guard state == .ready else {
            ping.stop()
            sink.state(state.linkState)
            return
        }
        sink.state(.connected)
        lastHeard = .now
        osc("\(base)/fader/1/config/\(count)")
        osc("/eos/subscribe", [.int(1)])
        ping.start(every: 5) { [weak self] in
            guard let self else { return }
            if ContinuousClock.now - self.lastHeard > .seconds(15) {
                self.ping.stop()
                self.sink.state(.failed("Eos stopped answering"))
            } else {
                self.osc("/eos/ping")
            }
        }
        // Eos answers the subscription with the bank's levels and names.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.sink.synced()
        }
    }

    private func receive(_ data: Data) {
        lastHeard = .now
        for packet in framer.feed(data) {
            for message in OSCMessage.decode(packet) {
                let parts = message.address.split(separator: "/")
                // eos out fader 1 <n> [name]
                guard parts.count >= 5, parts[0] == "eos", parts[1] == "out", parts[2] == "fader", parts[3] == "1",
                      let n = Int(parts[4]), (1...count).contains(n) else { continue }
                if parts.count == 5, let v = message.arguments.first?.number {
                    sink.value(ControlID("fader.\(n).level"), .level(clamp01(v)))
                } else if parts.count == 6, parts[5] == "name", let name = message.arguments.first?.string {
                    sink.name("fader.\(n)", name)
                }
            }
        }
    }
}
