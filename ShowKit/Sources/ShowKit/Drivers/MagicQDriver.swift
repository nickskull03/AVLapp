import Foundation

/// ChamSys MagicQ over OSC/UDP. `/pb/<n>` sets playback n's level (0–1);
/// `/pb/<n>/go`, `/pb/<n>/stop` and `/pb/<n>/flash` work its buttons. MagicQ's
/// built-in OSC covers playbacks 1–10. With an OSC TX port set, MagicQ
/// reports playback levels back.
///
/// The key panel uses MagicQ's remote protocol through OSC `/rpc`: `1G` is Go
/// on playback 1, `1S` Stop, `1B` and `1F` fast back and forward, `1A` and
/// `1R` activate and release, `1,5J` jump to cue 5.
@MainActor
final class MagicQDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("jump", "Jump to cue", .command(hint: "Playback and cue: 1 5"))
    ]
    let traits: DriverTraits

    /// Remote protocol letters for the panel's keys.
    static let rpcLetters = ["go": "G", "stop": "S", "back": "B", "fwd": "F", "activate": "A", "release": "R"]

    /// One row per playback: Go, Stop, fast back and forward, activate, release.
    static let panel: KeyPanel = {
        let columns: [(String, String, PanelKey.Role)] = [
            ("go", "Go", .go), ("stop", "Stop", .stop), ("back", "◀◀", .normal), ("fwd", "▶▶", .normal),
            ("activate", "Act", .keyword), ("release", "Rel", .clear)
        ]
        let rows: [[PanelKey]] = (1...10).map { (n: Int) -> [PanelKey] in
            let keys: [PanelKey] = columns.map { column in
                PanelKey("rpc.\(n).\(column.0)", column.1, .trigger(ControlID("rpc.\(n).\(column.0)")), role: column.2)
            }
            return [PanelKey("label.\(n)", "PB \(n)", .label)] + keys
        }
        return KeyPanel(commandLine: .none, sections: [KeySection(id: "playbacks", title: "Playbacks", rows: rows)])
    }()

    var keyPanel: KeyPanel? { Self.panel }

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
        if id.rawValue == "jump", case .text(let text) = value {
            if let command = Self.jumpCommand(text) { rpc(command) }
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, let n = Int(parts[1]) else { return }
        if parts[0] == "rpc" {
            if case .trigger = value, let letter = Self.rpcLetters[String(parts[2])] { rpc("\(n)\(letter)") }
            return
        }
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

    /// "1 5" → "1,5J"; "1 5.5" → "1,5,5J" (cue 5.5 on playback 1).
    static func jumpCommand(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count == 2, let playback = Int(words[0]), (1...202).contains(playback),
              let cue = GrandMA3Driver.cueNumber(words[1]) else { return nil }
        let pieces = cue.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int(pieces[0]), (1...65536).contains(whole) else { return nil }
        if pieces.count == 2, let fraction = Int(pieces[1]) { return "\(playback),\(whole),\(fraction)J" }
        return pieces.count == 1 ? "\(playback),\(whole)J" : nil
    }

    private func rpc(_ command: String) {
        transport.send(OSCMessage("/rpc", [.string(command)]).encoded())
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
