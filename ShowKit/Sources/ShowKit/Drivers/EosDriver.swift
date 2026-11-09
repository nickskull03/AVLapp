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
        ControlDescriptor("goto", "Go to cue", .command(hint: "Cue number, or list/cue: 5 or 2/5")),
        ControlDescriptor("cuetime", "Set cue time", .command(hint: "Cue and seconds: 5 3")),
        ControlDescriptor("update", "Update cue", .command(hint: "Cue number: updates it with your changes"), needsConfirmation: true),
        ControlDescriptor("command", "Command", .command(hint: "Any Eos command, e.g. Chan 1 At Full"))
    ]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    /// Eos's face panel. Each key is pressed and released on the console
    /// (`/eos/key/<name>`, 1 then 0), so it lands on the app's OSC user's
    /// command line exactly as on the desk, and Eos reports the line back.
    static let panel: KeyPanel = {
        func key(_ name: String, _ label: String? = nil, _ role: PanelKey.Role = .keyword, span: Int = 1) -> PanelKey {
            PanelKey("key.\(name)", label ?? name, .press(ControlID("key.\(name)")), role: role, span: span)
        }
        func n(_ d: String) -> PanelKey { key(d, d, .number) }
        return KeyPanel(commandLine: .console(infoKey: "device.cmdline"), sections: [
            KeySection(id: "targets", title: "Targets", rows: [
                [key("chan", "Chan"), key("group", "Group"), key("cue", "Cue")],
                [key("sub", "Sub"), key("macro", "Macro"), key("preset", "Preset")],
                [key("part", "Part"), key("time", "Time"), key("delay", "Delay")]
            ]),
            KeySection(id: "functions", title: "Functions", rows: [
                [key("record", "Record"), key("update", "Update"), key("delete", "Delete", .clear)],
                [key("copy_to", "Copy To"), key("label", "Label"), key("sneak", "Sneak")],
                [key("highlight", "Highlight"), key("rem_dim", "Rem Dim"), key("undo", "Undo", .clear)],
                [key("last", "Last"), key("next", "Next"), key("home", "Home")]
            ]),
            KeySection(id: "numbers", title: "Numbers", rows: [
                [key("at", "@"), key("thru", "Thru"), key("full", "Full")],
                [key("+", "+", .normal), key("-", "−", .normal), key("out", "Out")],
                [n("7"), n("8"), n("9")],
                [n("4"), n("5"), n("6")],
                [n("1"), n("2"), n("3")],
                [key("0", "0", .number, span: 2), n(".")],
                [key("clear_cmd", "Clear", .clear), key("level", "Level", .normal), key("enter", "Enter", .enter)]
            ]),
            KeySection(id: "playback", title: "Playback", rows: [
                [key("go_0", "Go", .go, span: 2), key("stop_back", "Stop/Back", .stop)]
            ])
        ])
    }()

    var keyPanel: KeyPanel? { Self.panel }

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
        case ("goto", .text(let text)):
            // "5" fires cue 5 in list 1; "2/5" fires cue 5 in list 2.
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/").map(String.init)
            guard (1...2).contains(parts.count), parts.allSatisfy({ GrandMA3Driver.cueNumber($0) != nil }) else { return }
            osc(parts.count == 2 ? "\(base)/cue/\(parts[0])/\(parts[1])/fire" : "\(base)/cue/1/\(parts[0])/fire")
            return
        case ("cuetime", .text(let text)):
            let words = text.split(separator: " ").map(String.init)
            guard words.count == 2, let cue = GrandMA3Driver.cueNumber(words[0]), Double(words[1]) != nil else { return }
            osc("\(base)/cmd", [.string("Cue \(cue) Time \(words[1])#")])
            return
        case ("update", .text(let text)):
            guard let cue = GrandMA3Driver.cueNumber(text) else { return }
            osc("\(base)/cmd", [.string("Update Cue \(cue)#")])
            return
        case ("command", .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { osc("\(base)/cmd", [.string(trimmed + "#")]) } // # = Enter
            return
        default:
            break
        }
        if id.rawValue.hasPrefix("key."), case .press(let down) = value {
            osc("\(base)/key/\(id.rawValue.dropFirst(4))", [.float(down ? 1 : 0)])
            return
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
                // eos out cmd, or eos out user <n> cmd: the command line
                if parts.count >= 3, parts[0] == "eos", parts[1] == "out", parts.last == "cmd",
                   parts.count == 3 || (parts.count == 5 && parts[2] == "user") {
                    let text = message.arguments.first?.string ?? ""
                    sink.info("device.cmdline", text.isEmpty ? nil : text)
                    continue
                }
                // eos out active|pending cue text: what's running and what's next
                if parts.count == 5, parts[0] == "eos", parts[1] == "out", parts[3] == "cue", parts[4] == "text",
                   parts[2] == "active" || parts[2] == "pending" {
                    let text = message.arguments.first?.string ?? ""
                    sink.info("device.cue.\(parts[2])", text.isEmpty ? nil : text)
                    continue
                }
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
