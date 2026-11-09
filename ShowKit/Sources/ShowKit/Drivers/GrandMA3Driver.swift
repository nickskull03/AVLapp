import Foundation

/// grandMA3 over OSC/UDP.
///
/// Each strip is one executor column on the current page: x01 is column 1.
/// Top to bottom, as on the console: 4xx and 3xx (a key and a knob each), the
/// 2xx key, the 2xx fader, and the 1xx key under the fader. Which rows show is
/// up to the user.
///
/// - Faders and knobs: `/<prefix>/Page<p>/Fader<exec>`, scaled to the OSC
///   line's Fader Range.
/// - Keys: `/<prefix>/Page<p>/Key<exec>`, 1 on press and 0 on release, doing
///   whatever the key does on the desk. A key can instead be set to send a
///   fixed command (Go+, Toggle, …) to its executor.
/// - Everything else is a command line to `/<prefix>/cmd`, which needs Receive
///   Command on in MA3: Go+, Go−, Goto Cue, CueFade, Store /Merge.
///
/// With the Show Deck plugin running on the console (see `MA3/README.md`),
/// MA3 also reports executor names, running states, current and next cues,
/// and the page it's on:
///
///     /<prefix>/Page1/Name201 ,s "Front Wash"
///     /<prefix>/Page1/Active201 ,i 1
///     /<prefix>/Page1/Cue201 ,s "3 Verse"
///     /<prefix>/Page1/NextCue201 ,s "4 Chorus"
///     /<prefix>/Page1/Fader201 ,i 75
///     /<prefix>/CurrentPage ,i 1
@MainActor
final class GrandMA3Driver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("page", "Page", .number(1...9999)),
        ControlDescriptor("command", "Command", .command(hint: "Any MA command, e.g. Go+ Sequence 3"))
    ]
    let traits: DriverTraits

    static let actions = [
        ButtonAction("key", "As set on the desk"),
        ButtonAction("go", "Go+"),
        ButtonAction("back", "Go−"),
        ButtonAction("toggle", "Toggle"),
        ButtonAction("on", "On"),
        ButtonAction("off", "Off"),
        ButtonAction("top", "Top"),
        ButtonAction("select", "Select")
    ]

    /// The panel's immediate keys and the command each sends.
    static let panelCommands = [
        "goplus": "Go+", "gominus": "Go-", "pause": "Pause", "clear": "Clear", "clearall": "ClearAll",
        "oops": "Oops", "highlight": "Highlight", "blind": "Blind", "freeze": "Freeze"
    ]

    /// MA3's keys. MA takes whole command lines over OSC, not key presses, so
    /// the keys build the line in the app and Please sends it; Go+, Go−,
    /// Pause, Oops and the like act at once. With nothing typed, Go+ and Go−
    /// work the selected executor, as on the desk.
    static let panel: KeyPanel = {
        func now(_ id: String, _ label: String, _ role: PanelKey.Role = .normal) -> PanelKey {
            PanelKey("panel.\(id)", label, .trigger(ControlID("panel.\(id)")), role: role)
        }
        let w = { (text: String) in PanelKey.word(text) }
        return KeyPanel(commandLine: .local(send: "command"), sections: [
            KeySection(id: "objects", title: "Objects", rows: [
                [w("Fixture"), w("Group"), w("Preset")],
                [w("Sequence"), w("Cue"), w("Executor")],
                [w("Page"), w("Macro"), w("Effect")]
            ]),
            KeySection(id: "functions", title: "Functions", rows: [
                [w("Store"), w("Update"), w("Delete")],
                [w("Copy"), w("Move"), w("Assign")],
                [w("Label"), w("Edit"), w("Time")]
            ]),
            KeySection(id: "numbers", title: "Numbers", rows: [
                [w("At"), w("Thru"), w("Full")],
                [PanelKey.word("+", role: .normal), PanelKey.word("-", role: .normal), PanelKey.word("If", role: .normal)]
            ] + PanelKey.numberPad() + [[
                PanelKey("clear", "Clear", .clear(ControlID("panel.clear")), role: .clear),
                PanelKey("backspace", "⌫", .backspace, role: .clear),
                PanelKey("enter", "Please", .enter, role: .enter)
            ]]),
            KeySection(id: "playback", title: "Playback", rows: [
                [now("goplus", "Go+", .go), now("gominus", "Go−"), now("pause", "Pause", .stop)],
                [now("highlight", "Highlight"), now("blind", "Blind"), now("freeze", "Freeze")],
                [now("oops", "Oops", .clear), PanelKey("panel.clearall", "Clear All", .trigger(ControlID("panel.clearall")), role: .clear, span: 2)]
            ])
        ])
    }()

    var keyPanel: KeyPanel? { Self.panel }

    static let commandKeywords = ["go": "Go+", "back": "Go-", "toggle": "Toggle", "on": "On", "off": "Off", "top": "Top", "select": "Select"]

    private let config: DeviceConfig
    private let transport: Transport
    private let prefix: String
    private let columns: [Int]
    private var page: Int
    private var heard = false
    private var actions: [String: String] = [:] // control ID -> action ID
    /// page -> executor -> 0...1, so paging back shows where faders were.
    private var levels: [Int: [Int: Double]] = [:]
    /// page -> info key -> text (names, cues, running states).
    private var pageInfo: [Int: [String: String]] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        self.config = config
        page = max(1, config.page)
        prefix = config.oscPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        traits = DriverTraits(
            reportsChanges: config.feedbackPort != 0, readsNames: true,
            note: "Names, cues and running states come from the Show Deck plugin on the console.",
            buttonActions: Self.actions
        )
        let listen: UInt16? = config.feedbackPort == 0 ? nil : config.feedbackPort16
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: listen))

        let first = max(1, min(90, config.firstNumber))
        let count = max(1, min(91 - first, config.count))
        let columns = Array(first..<first + count)
        self.columns = columns
        let rows = Set(config.executorRows.isEmpty ? [1, 2] : config.executorRows)
        groups = [StripGroup(id: "exec", title: "Executors", strips: columns.map { Self.column($0, rows: rows) })]

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    /// The strip for column `n` (executors 1nn–4nn).
    static func column(_ n: Int, rows: Set<Int>) -> Strip {
        func key(_ row: Int) -> ControlDescriptor {
            ControlDescriptor(ControlID("exec.\(row * 100 + n).key"), "\(row * 100 + n)", .momentary)
        }
        func knob(_ row: Int) -> ControlDescriptor {
            ControlDescriptor(ControlID("exec.\(row * 100 + n).level"), "\(row * 100 + n)",
                              .parameter(ParameterSpec(0, 100, unit: "%", decimals: 0)))
        }
        var buttons: [ControlDescriptor] = []
        for row in [4, 3] where rows.contains(row) { buttons += [knob(row), key(row)] }
        if rows.contains(2) { buttons.append(key(2)) }
        let main = rows.contains(2) ? 200 + n : (rows.sorted().first ?? 2) * 100 + n
        let cues = ControlSection(id: "cues", title: "Cues on \(main)", controls: [
            ControlDescriptor(ControlID("exec.\(main).go"), "Go+", .trigger),
            ControlDescriptor(ControlID("exec.\(main).back"), "Go−", .trigger),
            ControlDescriptor(ControlID("exec.\(main).goto"), "Go to cue", .command(hint: "Cue number, e.g. 5 or 5.5")),
            ControlDescriptor(ControlID("exec.\(main).cuefade"), "Set cue fade",
                              .command(hint: "Cue and seconds: 5 3, or in/out: 5 3/6")),
            ControlDescriptor(ControlID("exec.\(main).update"), "Update cue", .command(hint: "Cue number: merges the programmer into it"),
                              needsConfirmation: true)
        ])
        return Strip(
            id: "col.\(n)", name: "Exec \(main)", style: .playback,
            fader: rows.contains(2) ? ControlDescriptor(ControlID("exec.\(200 + n).level"), "Fader", .fader(.percent)) : nil,
            buttons: buttons,
            lowerButtons: rows.contains(1) ? [key(1)] : [],
            sections: [cues]
        )
    }

    func start() {
        heard = false
        transport.open()
    }

    func stop() {
        transport.close()
    }

    func apply(customizations: [String: StripCustomization]) {
        actions = customizations.values.reduce(into: [:]) { result, custom in
            result.merge(custom.actions) { _, new in new }
        }
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id.rawValue, value) {
        case ("page", .number(let newPage)):
            showPage(max(1, newPage))
            return
        case ("command", .text(let text)):
            command(text)
            return
        default:
            break
        }
        if id.rawValue.hasPrefix("panel."), case .trigger = value {
            if let text = Self.panelCommands[String(id.rawValue.dropFirst(6))] { command(text) }
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[0] == "exec", let exec = Int(parts[1]) else { return }
        let target = "Executor \(page).\(exec)"
        switch (parts[2], value) {
        case ("level", .level(let position)):
            levels[page, default: [:]][exec] = position
            osc("Page\(page)/Fader\(exec)", .float(Float(clamp01(position) * config.faderRange)))
        case ("key", .press(let down)):
            let action = actions[id.rawValue] ?? "key"
            if action == "key" {
                osc("Page\(page)/Key\(exec)", .int(down ? 1 : 0))
            } else if down, let keyword = Self.commandKeywords[action] {
                command("\(keyword) \(target)")
            }
        case ("go", .trigger):
            command("Go+ \(target)")
        case ("back", .trigger):
            command("Go- \(target)")
        case ("goto", .text(let text)):
            if let cue = Self.cueNumber(text) { command("Goto Cue \(cue) \(target)") }
        case ("cuefade", .text(let text)):
            // "5 3" or "5 3/6": select the executor's sequence, then set the cue's fade.
            let words = text.split(separator: " ").map(String.init)
            guard words.count == 2, let cue = Self.cueNumber(words[0]), let time = Self.fadeTime(words[1]) else { return }
            command("Select \(target)")
            command("Cue \(cue) CueFade \(time)")
        case ("update", .text(let text)):
            guard let cue = Self.cueNumber(text) else { return }
            command("Select \(target)")
            command("Store Cue \(cue) /Merge")
        default:
            break
        }
    }

    // MARK: Parsing what the user typed

    /// "5", "5.5" → itself; anything else → nil, so nothing odd reaches the command line.
    static func cueNumber(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." }), Double(t) != nil else { return nil }
        return t
    }

    /// "3", "1.5", "3/6", "3/" → itself.
    static func fadeTime(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), Double(parts[0]) != nil,
              parts.count == 1 || parts[1].isEmpty || Double(parts[1]) != nil else { return nil }
        return text
    }

    // MARK: Private

    private func osc(_ rest: String, _ argument: OSCArgument) {
        let address = prefix.isEmpty ? "/\(rest)" : "/\(prefix)/\(rest)"
        transport.send(OSCMessage(address, [argument]).encoded())
    }

    private func command(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        osc("cmd", .string(trimmed))
    }

    private func transportState(_ state: TransportState) {
        switch state {
        case .ready:
            // MA3 doesn't answer OSC, so we can only say we're sending,
            // until feedback arrives. There's no state to read either.
            sink.state(heard ? .connected : .sending)
            sink.synced()
        default:
            sink.state(state.linkState)
        }
    }

    /// Switches to a page and shows what's known about it.
    private func showPage(_ newPage: Int) {
        let oldInfo = pageInfo[page] ?? [:]
        page = newPage
        let info = pageInfo[page] ?? [:]
        for key in oldInfo.keys where info[key] == nil { sink.info(key, nil) }
        for (key, text) in info { sink.info(key, text) }
        for n in columns {
            for row in 1...4 {
                let exec = row * 100 + n
                if row >= 2 { sink.value(ControlID("exec.\(exec).level"), .level(levels[page]?[exec] ?? 0)) }
            }
            sink.name("col.\(n)", info["exec.\(200 + n).name"] ?? info["exec.\(100 + n).name"] ?? "")
        }
    }

    private func receive(_ data: Data) {
        if !heard {
            heard = true
            sink.state(.connected)
        }
        for message in OSCMessage.decode(data) {
            let parts = message.address.split(separator: "/").map(String.init)
            if parts.last == "CurrentPage", let p = message.arguments.first?.number {
                if config.followDeskPage, Int(p) != page, Int(p) >= 1 { showPage(Int(p)) }
                continue
            }
            guard let i = parts.firstIndex(where: { $0.hasPrefix("Page") }), i + 1 < parts.count,
                  let msgPage = Int(parts[i].dropFirst(4)) else { continue }
            let item = parts[i + 1]
            guard case let (kind, exec)? = Self.split(item) else { continue }
            let argument = message.arguments.lazy.compactMap { $0.number }.first
            let text = message.arguments.lazy.compactMap { $0.string }.first
            switch kind {
            case "Fader":
                guard let value = argument, config.faderRange > 0 else { continue }
                let level = clamp01(value / config.faderRange)
                levels[msgPage, default: [:]][exec] = level
                if msgPage == page { sink.value(ControlID("exec.\(exec).level"), .level(level)) }
            case "Name":
                setInfo("exec.\(exec).name", text.flatMap { $0 == "-" ? nil : $0 }, page: msgPage)
                let n = exec % 100
                if msgPage == page, exec / 100 == 2 || (exec / 100 == 1 && pageInfo[page]?["exec.\(200 + n).name"] == nil) {
                    sink.name("col.\(n)", text == "-" ? "" : text ?? "")
                }
            case "Active":
                setInfo("exec.\(exec).active", (argument ?? 0) >= 0.5 ? "1" : nil, page: msgPage)
            case "Cue":
                setInfo("exec.\(exec).cue", text.flatMap { $0 == "-" ? nil : $0 }, page: msgPage)
            case "NextCue":
                setInfo("exec.\(exec).next", text.flatMap { $0 == "-" ? nil : $0 }, page: msgPage)
            default:
                break
            }
        }
    }

    private func setInfo(_ key: String, _ text: String?, page msgPage: Int) {
        pageInfo[msgPage, default: [:]][key] = text
        if msgPage == page { sink.info(key, text) }
    }

    /// "Fader201" -> ("Fader", 201)
    static func split(_ item: String) -> (String, Int)? {
        guard let digit = item.firstIndex(where: \.isNumber), let exec = Int(item[digit...]) else { return nil }
        return (String(item[..<digit]), exec)
    }
}
