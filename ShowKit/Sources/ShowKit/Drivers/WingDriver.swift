import Foundation

/// Behringer Wing (Full, Compact and Rack) over OSC on UDP 2223.
///
/// - Values are in real units: faders in dB (−144 is −∞, up to +10), gain in
///   dB, frequencies in Hz. Switches are 0/1; `…/mute` is 1 when muted.
/// - The Wing answers a query (an address with no arguments) with the value as
///   text, its 0–1 position and its value (",sff"), or just the text for names.
/// - It only reports changes made elsewhere while subscribed: `/*S`, renewed
///   every few seconds (it lapses after 10). Only one app can hold the
///   subscription at a time.
/// - Scenes: `/$ctl/lib/$actionidx` with the scene number, then
///   `/$ctl/lib/$action` with "GO".
///
/// Paths are from the Bitfocus Companion Wing module.
@MainActor
final class WingDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls = [ControlDescriptor("scene", "Recall scene", .number(1...999), needsConfirmation: true)]
    let traits = DriverTraits(
        reportsChanges: true, readsNames: true,
        note: "On the Wing, the app switches EQ, gate and compressor in and out, and sets gain and low-cut. Their other settings stay on the console."
    )

    static let gainSpec = ParameterSpec(-3, 45.5, unit: "dB")
    static let lowCutSpec = ParameterSpec(20, 2000, unit: "Hz", curve: .logarithmic, decimals: 0)

    private enum Target {
        case fader(ControlID) // dB
        case mute(ControlID) // 1 = muted
        case enable(ControlID) // 1 = on
        case parameter(ControlID, ParameterSpec) // real units
        case name(String)
    }

    private let config: DeviceConfig
    private let transport: Transport
    private var targets: [String: Target] = [:]
    private var addresses: [ControlID: String] = [:]
    private var detailQueries: [String: [String]] = [:]
    private let heartbeat = Ticker()
    private let pacer = QueryPacer()
    private var lastHeard: ContinuousClock.Instant?
    private var openedAt: ContinuousClock.Instant = .now
    private var answered = false

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        self.config = config
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: nil))

        var targets: [String: Target] = [:]
        var addresses: [ControlID: String] = [:]
        var detailQueries: [String: [String]] = [:]

        func bind(_ id: ControlID, _ address: String, _ target: Target) {
            targets[address] = target
            addresses[id] = address
        }

        func strip(_ kind: String, _ n: Int, _ name: String, _ style: StripStyle,
                   fader: Bool = true, input: Bool = false, confirmMute: Bool = false) -> Strip {
            let id = "\(kind).\(n)"
            let base = "/\(kind)/\(n)"
            let muteID = ControlID("\(id).mute")
            bind(muteID, "\(base)/mute", .mute(muteID))
            targets["\(base)/name"] = .name(id)
            var faderControl: ControlDescriptor? = nil
            if fader {
                let levelID = ControlID("\(id).level")
                bind(levelID, "\(base)/fdr", .fader(levelID))
                faderControl = ControlDescriptor(levelID, "Fader", .fader(.decibels))
            }
            var gain: ControlDescriptor? = nil
            var sections: [ControlSection] = []
            if input {
                let gainID = ControlID("\(id).gain")
                bind(gainID, "\(base)/in/set/$g", .parameter(gainID, Self.gainSpec))
                gain = ControlDescriptor(gainID, "Gain", .parameter(Self.gainSpec))

                func enable(_ suffix: String, _ path: String, _ label: String) -> ControlDescriptor {
                    let controlID = ControlID("\(id).\(suffix)")
                    bind(controlID, "\(base)/\(path)", .enable(controlID))
                    return ControlDescriptor(controlID, label, .toggle(.enable))
                }
                let lowCutFreq = ControlID("\(id).lc.freq")
                bind(lowCutFreq, "\(base)/flt/lcf", .parameter(lowCutFreq, Self.lowCutSpec))
                sections = [
                    ControlSection(id: "lc", title: "Low-cut", controls: [
                        enable("lc.on", "flt/lc", "Low-cut on"),
                        ControlDescriptor(lowCutFreq, "Frequency", .parameter(Self.lowCutSpec))
                    ]),
                    ControlSection(id: "eq", title: "EQ", controls: [enable("eq.on", "eq/on", "EQ on")]),
                    ControlSection(id: "gate", title: "Gate", controls: [enable("gate.on", "gate/on", "Gate on")]),
                    ControlSection(id: "comp", title: "Compressor", controls: [enable("comp.on", "dyn/on", "Compressor on")])
                ]
                detailQueries[id] = ["flt/lc", "flt/lcf", "eq/on", "gate/on", "dyn/on"].map { "\(base)/\($0)" }
            }
            return Strip(
                id: id, name: name, style: style, fader: faderControl,
                buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute), needsConfirmation: confirmMute)],
                gain: gain, sections: sections
            )
        }

        groups = [
            StripGroup(id: "ch", title: "Channels", strips: (1...40).map { strip("ch", $0, "Ch \($0)", .input, input: true) }),
            StripGroup(id: "aux", title: "Aux Ins", strips: (1...8).map { strip("aux", $0, "Aux \($0)", .input) }),
            StripGroup(id: "bus", title: "Buses", strips: (1...16).map { strip("bus", $0, "Bus \($0)", .bus) }),
            StripGroup(id: "mtx", title: "Matrices", strips: (1...8).map { strip("mtx", $0, "Mtx \($0)", .bus) }),
            StripGroup(id: "dca", title: "DCAs", strips: (1...16).map { strip("dca", $0, "DCA \($0)", .dca) }),
            StripGroup(id: "main", title: "Mains", strips: (1...4).map { strip("main", $0, "Main \($0)", .master, confirmMute: true) }),
            StripGroup(id: "mgrp", title: "Mute Groups", strips: (1...8).map { strip("mgrp", $0, "Mute \($0)", .muteGroup, fader: false) })
        ]
        self.targets = targets
        self.addresses = addresses
        self.detailQueries = detailQueries

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        answered = false
        lastHeard = nil
        transport.open()
    }

    func stop() {
        heartbeat.stop()
        pacer.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        if id == "scene", case .number(let n) = value {
            osc("/$ctl/lib/$actionidx", .int(Int32(n)))
            osc("/$ctl/lib/$action", .string("GO"))
            return
        }
        guard let address = addresses[id], let target = targets[address] else { return }
        switch (target, value) {
        case (.fader, .level(let position)):
            osc(address, .float(Float(AudioTaper.decibels(position: position) ?? -144)))
        case (.mute, .on(let on)), (.enable, .on(let on)):
            osc(address, .int(on ? 1 : 0))
        case (.parameter(_, let spec), .level(let position)):
            osc(address, .float(Float(spec.value(at: position))))
        default:
            break
        }
    }

    func detailOpened(_ stripID: String) {
        for address in detailQueries[stripID] ?? [] {
            transport.send(OSCMessage(address).encoded())
        }
    }

    // MARK: Private

    private func osc(_ address: String, _ argument: OSCArgument) {
        transport.send(OSCMessage(address, [argument]).encoded())
    }

    private func transportState(_ state: TransportState) {
        sink.state(state.linkState)
        guard state == .ready else {
            heartbeat.stop()
            return
        }
        openedAt = .now
        heartbeat.start(every: 4, immediately: true) { [weak self] in self?.pulse() }
    }

    /// Renews the subscription and asks something with an answer, to know the Wing is there.
    private func pulse() {
        transport.send(OSCMessage("/*S").encoded())
        transport.send(OSCMessage("/main/1/fdr").encoded())
        let now = ContinuousClock.now
        if let lastHeard {
            if now - lastHeard > .seconds(10) {
                heartbeat.stop()
                sink.state(.failed("The Wing stopped answering"))
            }
        } else if now - openedAt > .seconds(7) {
            heartbeat.stop()
            sink.state(.failed("No answer from \(config.trimmedHost):\(config.port)"))
        }
    }

    /// The value in a reply: the third argument of ",sff", else the first number,
    /// else the text read as a number ("-oo" is −∞, so nil).
    static func value(_ arguments: [OSCArgument]) -> Double? {
        if arguments.count >= 3, let v = arguments[2].number { return v }
        if let v = arguments.lazy.compactMap(\.number).first { return v }
        if let text = arguments.first?.string { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private func receive(_ data: Data) {
        lastHeard = .now
        if !answered {
            answered = true
            sink.state(.connected)
            readEverything()
        }
        for message in OSCMessage.decode(data) {
            guard let target = targets[message.address] else { continue }
            switch target {
            case .fader(let id):
                let db = Self.value(message.arguments)
                sink.value(id, .level(AudioTaper.position(decibels: (db ?? -144) <= -144 ? nil : db)))
            case .mute(let id), .enable(let id):
                if let v = Self.value(message.arguments) { sink.value(id, .on(v >= 0.5)) }
            case .parameter(let id, let spec):
                if let v = Self.value(message.arguments) { sink.value(id, .level(spec.position(for: v))) }
            case .name(let stripID):
                if let name = message.arguments.first?.string { sink.name(stripID, name) }
            }
        }
    }

    /// Faders, mutes, names and gains: what the strips show. Processing is read
    /// when a strip's detail opens.
    private func readEverything() {
        let processing = Set(detailQueries.values.joined())
        let queries = targets.keys.filter { !processing.contains($0) }.sorted().map { OSCMessage($0).encoded() }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.sink.synced()
            }
        }
    }
}
