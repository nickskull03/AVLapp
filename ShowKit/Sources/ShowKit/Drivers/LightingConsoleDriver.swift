import Foundation

/// The Lighting desktop console (nickskull03/lighting), over the WebSocket its
/// own windows use: `ws://<host>:<port>/ws`.
///
/// - The app sends command lines, `{"type":"command","id":1,"text":"Fader 3 At 50"}`,
///   and the console answers each with `{"type":"result","id":1,"ok":true,"message":"…"}`.
/// - The console pushes `{"type":"state", …}` after every change (at most ~30 a
///   second): the show (faders, sequences and their cues) and playback (page,
///   grand master, blackout, each sequence's level and running cue).
///
/// Strips are the ten faders of the page the console is on. Commands name the
/// fader with its page (`Fader 2.3`), so they act on the right one from any page.
@MainActor
final class LightingConsoleDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("page", "Page", .number(1...99)),
        ControlDescriptor("command", "Command", .command(hint: "Any console command, e.g. Group 1 At Full"))
    ]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    static let faders = 10

    private let transport: Transport
    private var page = 1
    private var nextID = 1
    private var heard = false
    /// What was last reported, so only changes go to the sink.
    private var reported: [String: String] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        transport = makeTransport(.webSocket(url: "ws://\(config.trimmedHost):\(config.port)/ws"))
        groups = [
            StripGroup(id: "faders", title: "Faders", strips: (1...Self.faders).map(Self.faderStrip)),
            StripGroup(id: "master", title: "Master", strips: [
                Strip(id: "master", name: "Grand master", style: .master,
                      fader: ControlDescriptor("master.level", "Master", .fader(.percent)),
                      buttons: [ControlDescriptor("master.blackout", "Blackout", .toggle(.blackout), needsConfirmation: true)])
            ])
        ]
        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    static func faderStrip(_ n: Int) -> Strip {
        let id = "fader.\(n)"
        return Strip(
            id: id, name: "Fader \(n)", style: .playback,
            fader: ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.percent)),
            buttons: [ControlDescriptor(ControlID("\(id).flash"), "Flash", .momentary)],
            lowerButtons: [
                ControlDescriptor(ControlID("\(id).go"), "Go", .trigger),
                ControlDescriptor(ControlID("\(id).off"), "Off", .trigger)
            ],
            sections: [ControlSection(id: "cues", title: "Cues", controls: [
                ControlDescriptor(ControlID("\(id).back"), "Back", .trigger),
                ControlDescriptor(ControlID("\(id).pause"), "Pause", .trigger),
                ControlDescriptor(ControlID("\(id).goto"), "Go to cue", .command(hint: "Cue number, e.g. 5 or 2.5")),
                ControlDescriptor(ControlID("\(id).cuefade"), "Set cue fade", .command(hint: "Cue and seconds: 5 3")),
                ControlDescriptor(ControlID("\(id).store"), "Store cue", .command(hint: "Cue number: the programmer is merged into it"),
                                  needsConfirmation: true)
            ])]
        )
    }

    func start() {
        heard = false
        reported = [:]
        transport.open()
    }

    func stop() {
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id.rawValue, value) {
        case ("page", .number(let n)): command("Page \(n)"); return
        case ("command", .text(let text)): command(text); return
        case ("master.level", .level(let position)): command("Master At \(Self.percent(position))"); return
        case ("master.blackout", .on(let on)): command(on ? "Blackout" : "Blackout Off"); return
        default: break
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[0] == "fader", let n = Int(parts[1]) else { return }
        let fader = page == 1 ? "Fader \(n)" : "Fader \(page).\(n)"
        switch (parts[2], value) {
        case ("level", .level(let position)): command("\(fader) At \(Self.percent(position))")
        case ("go", .trigger): command("Go \(fader)")
        case ("back", .trigger): command("Back \(fader)")
        case ("pause", .trigger): command("Pause \(fader)")
        case ("off", .trigger): command("Off \(fader)")
        case ("flash", .press(let down)): command("Flash \(fader) \(down ? "On" : "Off")")
        case ("goto", .text(let text)):
            if let cue = GrandMA3Driver.cueNumber(text) { command("Goto Cue \(cue) \(fader)") }
        case ("cuefade", .text(let text)):
            let words = text.split(separator: " ").map(String.init)
            guard words.count == 2, let cue = GrandMA3Driver.cueNumber(words[0]), Double(words[1]) != nil else { return }
            command("Cue \(cue) \(fader) Fade \(words[1])")
        case ("store", .text(let text)):
            if let cue = GrandMA3Driver.cueNumber(text) { command("Store Cue \(cue) \(fader)") }
        default:
            break
        }
    }

    // MARK: Private

    static func percent(_ position: Double) -> Int {
        Int((clamp01(position) * 100).rounded())
    }

    private func command(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let message: [String: Any] = ["type": "command", "id": nextID, "text": trimmed]
        nextID += 1
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        transport.send(data)
    }

    private func transportState(_ state: TransportState) {
        // Connected once the socket is open; synced once the first state arrives.
        sink.state(state == .ready ? .connected : state.linkState)
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "state":
            readState(message)
            if !heard {
                heard = true
                sink.synced()
            }
        case "result":
            let ok = message["ok"] as? Bool ?? true
            sink.info("device.message", ok ? nil : message["message"] as? String)
        default:
            break
        }
    }

    /// "3 Verse", "2.5": a cue's number, and its name when it has one.
    static func cueLabel(_ number: Double, in sequence: [String: Any]?) -> String {
        let text = number == number.rounded() ? String(Int(number)) : String(number)
        let cues = sequence?["cues"] as? [[String: Any]] ?? []
        let name = cues.first { ($0["number"] as? Double) == number }?["name"] as? String ?? ""
        return name.isEmpty ? text : "\(text) \(name)"
    }

    private func readState(_ message: [String: Any]) {
        guard let playback = message["playback"] as? [String: Any],
              let show = message["show"] as? [String: Any] else { return }
        page = playback["page"] as? Int ?? page

        let assignments = show["faders"] as? [[String: Any]] ?? []
        let sequences = Dictionary(
            (show["sequences"] as? [[String: Any]] ?? []).compactMap { s in (s["id"] as? Int).map { ($0, s) } },
            uniquingKeysWith: { first, _ in first }
        )
        let statuses = Dictionary(
            (playback["sequences"] as? [[String: Any]] ?? []).compactMap { s in (s["id"] as? Int).map { ($0, s) } },
            uniquingKeysWith: { first, _ in first }
        )

        for n in 1...Self.faders {
            let id = "fader.\(n)"
            let sequenceID = assignments.first { $0["page"] as? Int == page && $0["fader"] as? Int == n }?["sequence"] as? Int
            let sequence = sequenceID.flatMap { sequences[$0] }
            let status = sequenceID.flatMap { statuses[$0] }
            let run = status?["run"] as? [String: Any]

            report(name: id, sequence?["name"] as? String ?? "")
            let level = (status?["level"] as? Double ?? 0) / 100
            report(value: ControlID("\(id).level"), .level(clamp01(level)))
            report(info: "\(id).cue", (run?["cue"] as? Double).map { Self.cueLabel($0, in: sequence) })
            report(info: "\(id).next", (status?["next"] as? Double).map { Self.cueLabel($0, in: sequence) })
            report(info: "\(id).active", run != nil || status?["flash"] as? Bool == true ? "1" : nil)
        }
        report(value: "master.level", .level(clamp01((playback["grandMaster"] as? Double ?? 100) / 100)))
        report(value: "master.blackout", .on(playback["blackout"] as? Bool ?? false))
    }

    private func report(name stripID: String, _ name: String) {
        guard reported["name.\(stripID)"] != name else { return }
        reported["name.\(stripID)"] = name
        sink.name(stripID, name)
    }

    private func report(value id: ControlID, _ value: ControlValue) {
        let key = "value.\(id.rawValue)"
        let text = String(describing: value)
        guard reported[key] != text else { return }
        reported[key] = text
        sink.value(id, value)
    }

    private func report(info key: String, _ text: String?) {
        let stored = text ?? "\u{0}"
        guard reported["info.\(key)"] != stored else { return }
        reported["info.\(key)"] = stored
        sink.info(key, text)
    }
}
