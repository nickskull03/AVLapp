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
        note: "Gate and compressor settings here are the Wing's standard GATE and COMP models, and the EQ is its STD model. If a channel uses another model (E88, 9000C, …), choose that on the console."
    )

    // Ranges from the Wing's own parameter list (libwing's propmap, Wing firmware 3.0.5).
    static let gainSpec = ParameterSpec(-3, 45.5, unit: "dB")
    static let trimSpec = ParameterSpec(-18, 18, unit: "dB")
    static let lowCutSpec = ParameterSpec(20, 2000, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let highCutSpec = ParameterSpec(50, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let eqGainSpec = ParameterSpec(-15, 15, unit: "dB")
    static let eqFreqSpec = ParameterSpec(20, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let eqQSpec = ParameterSpec(0.442, 10, curve: .logarithmic, decimals: 2)
    static let gateThresholdSpec = ParameterSpec(-80, 0, unit: "dB")
    static let gateRangeSpec = ParameterSpec(3, 60, unit: "dB")
    static let attackSpec = ParameterSpec(0, 120, unit: "ms", decimals: 0)
    static let holdSpec = ParameterSpec(1, 200, unit: "ms", decimals: 0)
    static let releaseSpec = ParameterSpec(4, 4000, unit: "ms", curve: .logarithmic, decimals: 0)
    static let percentSpec = ParameterSpec(0, 100, unit: "%", decimals: 0)
    static let compThresholdSpec = ParameterSpec(-60, 0, unit: "dB")
    static let compGainSpec = ParameterSpec(-6, 12, unit: "dB")
    static let panSpec = ParameterSpec(-100, 100, decimals: 0)
    static let gateRatios = ["1:1.5", "1:2", "1:3", "1:4", "gate"]
    static let compRatios: [Double] = [1.1, 1.2, 1.3, 1.5, 1.7, 2, 2.5, 3, 3.5, 4, 5, 6, 8, 10, 20, 50, 100]
    static let knees = ["0", "1", "2", "3", "4", "5"]
    static let detectors = ["PEAK", "RMS"]
    static let envelopes = ["LIN", "LOG"]
    static let lowCutSlopes = ["6", "12", "18", "24"]
    static let highCutSlopes = ["6", "12"]
    /// Shelf/peak choices for the outer bands; buses and mains also have cut filters.
    static let channelOuterTypes = ["PEQ", "SHV"]
    static let busOuterTypes = ["PEQ", "SHV", "CUT", "BW6", "BW12", "BS12", "LR12", "BW18", "BW24", "BS24", "LR24", "BW48", "LR48"]

    private enum Target {
        case fader(ControlID) // dB
        case mute(ControlID) // 1 = muted
        case enable(ControlID) // 1 = on
        case parameter(ControlID, ParameterSpec) // real units
        case text(ControlID, [String]) // sent and reported as the option's text
        case number(ControlID, [Double]) // sent and reported as the option's value
        case index(ControlID, Int) // sent and reported as 0..<count
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

        func control(_ id: String, _ suffix: String, _ path: String, _ label: String, _ kind: ControlKind, _ target: (ControlID) -> Target) -> ControlDescriptor {
            let controlID = ControlID("\(id).\(suffix)")
            bind(controlID, path, target(controlID))
            return ControlDescriptor(controlID, label, kind)
        }

        func parameter(_ id: String, _ suffix: String, _ path: String, _ label: String, _ spec: ParameterSpec) -> ControlDescriptor {
            control(id, suffix, path, label, .parameter(spec)) { .parameter($0, spec) }
        }

        func enable(_ id: String, _ suffix: String, _ path: String, _ label: String) -> ControlDescriptor {
            control(id, suffix, path, label, .toggle(.enable)) { .enable($0) }
        }

        func text(_ id: String, _ suffix: String, _ path: String, _ label: String, _ options: [String], shown: [String]? = nil) -> ControlDescriptor {
            control(id, suffix, path, label, .choice(shown ?? options)) { .text($0, options) }
        }

        /// The STD EQ: an outer low band, `inner` bands, an outer high band.
        func eqSection(_ id: String, _ base: String, inner: Int, outerTypes: [String]) -> ControlSection {
            var controls = [enable(id, "eq.on", "\(base)/eq/on", "EQ on")]
            var bands: [EQBand] = []
            let lowShapes: [FilterShape] = outerTypes.map { $0 == "PEQ" ? .peak : $0 == "SHV" ? .lowShelf : .lowCut }
            let highShapes: [FilterShape] = outerTypes.map { $0 == "PEQ" ? .peak : $0 == "SHV" ? .highShelf : .highCut }
            let names = ["l"] + (1...inner).map(String.init) + ["h"]
            for key in names {
                let label = key == "l" ? "Low" : key == "h" ? "High" : "Band \(key)"
                var type: ControlID? = nil
                if key == "l" || key == "h" {
                    let typeControl = text(id, "eq.\(key).type", "\(base)/eq/STD/\(key)eq", "\(label) type", outerTypes)
                    controls.append(typeControl)
                    type = typeControl.id
                }
                let freq = parameter(id, "eq.\(key).freq", "\(base)/eq/STD/\(key)f", "\(label) frequency", Self.eqFreqSpec)
                let gain = parameter(id, "eq.\(key).gain", "\(base)/eq/STD/\(key)g", "\(label) gain", Self.eqGainSpec)
                let q = parameter(id, "eq.\(key).q", "\(base)/eq/STD/\(key)q", "\(label) Q", Self.eqQSpec)
                controls += [freq, gain, q]
                let shapes: [FilterShape] = key == "l" ? lowShapes : key == "h" ? highShapes : [.peak]
                bands.append(EQBand(label: key.uppercased(), frequency: freq.id, gain: gain.id, q: q.id, type: type, shapes: shapes))
            }
            return ControlSection(id: "eq", title: "EQ", controls: controls,
                                  eq: EQLayout(on: ControlID("\(id).eq.on"), bands: bands))
        }

        func compSection(_ id: String, _ base: String) -> ControlSection {
            ControlSection(id: "comp", title: "Compressor", controls: [
                enable(id, "comp.on", "\(base)/dyn/on", "Compressor on"),
                parameter(id, "comp.thr", "\(base)/dyn/COMP/thr", "Threshold", Self.compThresholdSpec),
                control(id, "comp.ratio", "\(base)/dyn/COMP/ratio", "Ratio",
                        .choice(Self.compRatios.map { "\($0 == $0.rounded() ? String(Int($0)) : String($0)):1" })) { .number($0, Self.compRatios) },
                control(id, "comp.knee", "\(base)/dyn/COMP/knee", "Knee", .choice(Self.knees)) { .index($0, Self.knees.count) },
                parameter(id, "comp.attack", "\(base)/dyn/COMP/att", "Attack", Self.attackSpec),
                parameter(id, "comp.hold", "\(base)/dyn/COMP/hld", "Hold", Self.holdSpec),
                parameter(id, "comp.release", "\(base)/dyn/COMP/rel", "Release", Self.releaseSpec),
                parameter(id, "comp.gain", "\(base)/dyn/gain", "Gain", Self.compGainSpec),
                parameter(id, "comp.mix", "\(base)/dyn/mix", "Mix", Self.percentSpec),
                text(id, "comp.det", "\(base)/dyn/COMP/det", "Detector", Self.detectors, shown: ["Peak", "RMS"]),
                text(id, "comp.env", "\(base)/dyn/COMP/env", "Envelope", Self.envelopes, shown: ["Linear", "Log"]),
                enable(id, "comp.auto", "\(base)/dyn/COMP/auto", "Auto time")
            ])
        }

        func strip(_ kind: String, _ n: Int, _ name: String, _ style: StripStyle,
                   fader: Bool = true, input: Bool = false, output: Bool = false, confirmMute: Bool = false) -> Strip {
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
            let before = Set(addresses.values)
            if input {
                gain = parameter(id, "gain", "\(base)/in/set/$g", "Gain", Self.gainSpec)
                sections.append(ControlSection(id: "input", title: "Input", controls: [
                    parameter(id, "trim", "\(base)/in/set/trim", "Trim", Self.trimSpec),
                    enable(id, "invert", "\(base)/in/set/inv", "Phase invert"),
                    enable(id, "phantom", "\(base)/in/set/$vph", "Phantom power (48 V)")
                ]))
                sections.append(ControlSection(id: "filters", title: "Filters", controls: [
                    enable(id, "lc.on", "\(base)/flt/lc", "Low-cut on"),
                    parameter(id, "lc.freq", "\(base)/flt/lcf", "Low-cut frequency", Self.lowCutSpec),
                    text(id, "lc.slope", "\(base)/flt/lcs", "Low-cut slope (dB/oct)", Self.lowCutSlopes),
                    enable(id, "hc.on", "\(base)/flt/hc", "High-cut on"),
                    parameter(id, "hc.freq", "\(base)/flt/hcf", "High-cut frequency", Self.highCutSpec),
                    text(id, "hc.slope", "\(base)/flt/hcs", "High-cut slope (dB/oct)", Self.highCutSlopes)
                ]))
                sections.append(ControlSection(id: "gate", title: "Gate", controls: [
                    enable(id, "gate.on", "\(base)/gate/on", "Gate on"),
                    parameter(id, "gate.thr", "\(base)/gate/GATE/thr", "Threshold", Self.gateThresholdSpec),
                    parameter(id, "gate.range", "\(base)/gate/GATE/range", "Range", Self.gateRangeSpec),
                    text(id, "gate.ratio", "\(base)/gate/GATE/ratio", "Ratio", Self.gateRatios),
                    parameter(id, "gate.attack", "\(base)/gate/GATE/att", "Attack", Self.attackSpec),
                    parameter(id, "gate.hold", "\(base)/gate/GATE/hld", "Hold", Self.holdSpec),
                    parameter(id, "gate.release", "\(base)/gate/GATE/rel", "Release", Self.releaseSpec),
                    parameter(id, "gate.accent", "\(base)/gate/GATE/acc", "Accent", Self.percentSpec)
                ]))
                sections.append(compSection(id, base))
                sections.append(eqSection(id, base, inner: 4, outerTypes: Self.channelOuterTypes))
                var mix = [parameter(id, "pan", "\(base)/pan", "Pan", Self.panSpec)]
                for bus in 1...16 {
                    mix.append(control(id, "send.\(bus)", "\(base)/send/\(bus)/lvl", "Send to bus \(bus)", .fader(.decibels)) { .fader($0) })
                }
                sections.append(ControlSection(id: "sends", title: "Pan and sends", controls: mix))
            } else if output {
                sections.append(compSection(id, base))
                sections.append(eqSection(id, base, inner: 6, outerTypes: Self.busOuterTypes))
            }
            if !sections.isEmpty {
                detailQueries[id] = Array(Set(addresses.values).subtracting(before)).sorted()
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
            StripGroup(id: "bus", title: "Buses", strips: (1...16).map { strip("bus", $0, "Bus \($0)", .bus, output: true) }),
            StripGroup(id: "mtx", title: "Matrices", strips: (1...8).map { strip("mtx", $0, "Mtx \($0)", .bus, output: true) }),
            StripGroup(id: "dca", title: "DCAs", strips: (1...16).map { strip("dca", $0, "DCA \($0)", .dca) }),
            StripGroup(id: "main", title: "Mains", strips: (1...4).map { strip("main", $0, "Main \($0)", .master, output: true, confirmMute: true) }),
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
        case (.text(_, let options), .number(let i)) where options.indices.contains(i):
            osc(address, .string(options[i]))
        case (.number(_, let values), .number(let i)) where values.indices.contains(i):
            osc(address, .float(Float(values[i])))
        case (.index(_, let count), .number(let i)) where (0..<count).contains(i):
            osc(address, .int(Int32(i)))
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
            case .text(let id, let options):
                if let text = message.arguments.first?.string, let i = options.firstIndex(of: text) { sink.value(id, .number(i)) }
            case .number(let id, let values):
                if let v = Self.value(message.arguments),
                   let i = values.indices.min(by: { abs(values[$0] - v) < abs(values[$1] - v) }) { sink.value(id, .number(i)) }
            case .index(let id, _):
                if let v = Self.value(message.arguments) { sink.value(id, .number(Int(v.rounded()))) }
            case .name(let stripID):
                if let name = message.arguments.first?.string { sink.name(stripID, name) }
            }
        }
    }

    /// Faders, mutes, names and gains: what the strips show. Processing is read
    /// when a strip's detail opens.
    private func readEverything() {
        let processing = Set(detailQueries.values.joined())
        // Gain is on the strip itself, so it's read now too.
        let queries = targets.keys.filter { !processing.contains($0) || $0.hasSuffix("/in/set/$g") }.sorted().map { OSCMessage($0).encoded() }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.sink.synced()
            }
        }
    }
}
