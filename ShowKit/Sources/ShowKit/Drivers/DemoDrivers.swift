import Foundation

/// A mixer that lives inside the app, for trying Show Deck with no network:
/// sixteen named inputs with gain, high-pass, gate, compressor and a 4-band EQ,
/// four mixes and the main LR. It plays back whatever it's sent, as a real
/// desk reports its changes, and makes up a signal so the meters (and the
/// compressor's gain reduction) move.
@MainActor
final class DemoAudioDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls = [ControlDescriptor("scene", "Recall scene", .number(1...10), needsConfirmation: true)]
    let traits = DriverTraits(
        reportsChanges: true, readsNames: true,
        note: "This is the built-in demo mixer: nothing leaves the app."
    )

    static let names = ["Kick", "Snare", "Hi-hat", "Tom 1", "Tom 2", "OH L", "OH R", "Bass",
                        "Guitar", "Keys L", "Keys R", "Lead vox", "BV 1", "BV 2", "Track L", "Track R"]
    /// How loud each input's made-up source is, before gain (dBFS at 30 dB of gain).
    static let sourceLevels: [Double] = [-8, -10, -22, -14, -14, -20, -20, -12, -16, -18, -18, -10, -16, -16, -14, -14]

    static let ratios = ["1.1:1", "1.5:1", "2:1", "3:1", "4:1", "6:1", "10:1", "20:1", "∞:1"]
    static let gainSpec = ParameterSpec(0, 60, unit: "dB", decimals: 0)
    static let hpfSpec = ParameterSpec(20, 400, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let gateThresholdSpec = ParameterSpec(-80, 0, unit: "dB")
    static let rangeSpec = ParameterSpec(0, 60, unit: "dB", decimals: 0)
    static let compThresholdSpec = ParameterSpec(-60, 0, unit: "dB")
    static let kneeSpec = ParameterSpec(0, 12, unit: "dB")
    static let attackSpec = ParameterSpec(0.1, 120, unit: "ms", curve: .logarithmic)
    static let holdSpec = ParameterSpec(1, 2000, unit: "ms", curve: .logarithmic, decimals: 0)
    static let releaseSpec = ParameterSpec(5, 4000, unit: "ms", curve: .logarithmic, decimals: 0)
    static let makeupSpec = ParameterSpec(0, 24, unit: "dB")
    static let mixSpec = ParameterSpec(0, 100, unit: "%", decimals: 0)
    static let freqSpec = ParameterSpec(20, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let eqGainSpec = ParameterSpec(-15, 15, unit: "dB")
    static let qSpec = ParameterSpec(0.3, 10, curve: .logarithmic, decimals: 2)
    static let panSpec = ParameterSpec(-100, 100, decimals: 0)

    /// Every control's value, as the "desk" holds it.
    private var values: [ControlID: ControlValue] = [:]
    private var specs: [ControlID: ParameterSpec] = [:]
    private var choices: [ControlID: [String]] = [:]
    private let meterTicker = Ticker()
    private var time = 0.0
    private var running = false

    init(config: DeviceConfig, transport: TransportFactory) {
        var values: [ControlID: ControlValue] = [:]
        var specs: [ControlID: ParameterSpec] = [:]
        var choices: [ControlID: [String]] = [:]

        func param(_ id: String, _ label: String, _ spec: ParameterSpec, _ value: Double) -> ControlDescriptor {
            let cid = ControlID(id)
            specs[cid] = spec
            values[cid] = .level(spec.position(for: value))
            return ControlDescriptor(cid, label, .parameter(spec))
        }
        func toggle(_ id: String, _ label: String, _ on: Bool) -> ControlDescriptor {
            values[ControlID(id)] = .on(on)
            return ControlDescriptor(ControlID(id), label, .toggle(.enable))
        }
        func choice(_ id: String, _ label: String, _ options: [String], _ index: Int) -> ControlDescriptor {
            choices[ControlID(id)] = options
            values[ControlID(id)] = .number(index)
            return ControlDescriptor(ControlID(id), label, .choice(options))
        }
        func fader(_ id: String) -> ControlDescriptor {
            values[ControlID("\(id).level")] = .level(AudioTaper.unity)
            values[ControlID("\(id).mute")] = .on(false)
            return ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.decibels))
        }
        func mute(_ id: String, confirm: Bool = false) -> ControlDescriptor {
            ControlDescriptor(ControlID("\(id).mute"), "Mute", .toggle(.mute), needsConfirmation: confirm)
        }

        let inputs = (1...16).map { n -> Strip in
            let id = "ch.\(n)"
            let drum = n <= 7
            let eqBands: [(String, FilterShape, Double)] = [("1", .lowShelf, 100), ("2", .peak, 400), ("3", .peak, 2500), ("4", .highShelf, 8000)]
            var eqControls = [toggle("\(id).eq.on", "EQ on", true)]
            var layout: [EQBand] = []
            for (band, shape, freq) in eqBands {
                eqControls += [
                    param("\(id).eq.\(band).f", "Band \(band) frequency", Self.freqSpec, freq),
                    param("\(id).eq.\(band).g", "Band \(band) gain", Self.eqGainSpec, 0),
                    param("\(id).eq.\(band).q", "Band \(band) Q", Self.qSpec, 1.4)
                ]
                layout.append(EQBand(label: band, frequency: ControlID("\(id).eq.\(band).f"), gain: ControlID("\(id).eq.\(band).g"),
                                     q: ControlID("\(id).eq.\(band).q"), shapes: [shape]))
            }
            let sections = [
                ControlSection(id: "input", title: "Input", controls: [
                    toggle("\(id).hpf.on", "High-pass on", n != 1 && n != 8),
                    param("\(id).hpf.freq", "High-pass frequency", Self.hpfSpec, n == 12 ? 100 : 80)
                ]),
                ControlSection(id: "gate", title: "Gate", controls: [
                    toggle("\(id).gate.on", "Gate on", drum && n != 3),
                    param("\(id).gate.thr", "Threshold", Self.gateThresholdSpec, -40),
                    param("\(id).gate.range", "Range", Self.rangeSpec, 40),
                    param("\(id).gate.attack", "Attack", Self.attackSpec, 0.5),
                    param("\(id).gate.hold", "Hold", Self.holdSpec, 50),
                    param("\(id).gate.release", "Release", Self.releaseSpec, 150)
                ]),
                ControlSection(id: "comp", title: "Compressor", controls: [
                    toggle("\(id).comp.on", "Compressor on", n == 8 || n >= 12),
                    param("\(id).comp.thr", "Threshold", Self.compThresholdSpec, -18),
                    choice("\(id).comp.ratio", "Ratio", Self.ratios, 4),
                    param("\(id).comp.knee", "Knee", Self.kneeSpec, 4),
                    param("\(id).comp.attack", "Attack", Self.attackSpec, 10),
                    param("\(id).comp.release", "Release", Self.releaseSpec, 100),
                    param("\(id).comp.makeup", "Make-up gain", Self.makeupSpec, 3),
                    param("\(id).comp.mix", "Mix", Self.mixSpec, 100)
                ]),
                ControlSection(id: "eq", title: "EQ", controls: eqControls, eq: EQLayout(on: ControlID("\(id).eq.on"), bands: layout)),
                ControlSection(id: "sends", title: "Pan and sends", controls: [
                    param("\(id).pan", "Pan", Self.panSpec, n == 10 || n == 15 ? -100 : n == 11 || n == 16 ? 100 : 0)
                ] + (1...4).map { bus -> ControlDescriptor in
                    values[ControlID("\(id).send.\(bus)")] = .level(AudioTaper.position(decibels: bus == 1 && n >= 12 ? 0 : nil))
                    return ControlDescriptor(ControlID("\(id).send.\(bus)"), "Send to mix \(bus)", .fader(.decibels))
                })
            ]
            return Strip(id: id, name: Self.names[n - 1], style: .input, fader: fader(id), buttons: [mute(id)],
                         gain: param("\(id).gain", "Gain", Self.gainSpec, 30), sections: sections,
                         hasInputMeter: true, hasOutputMeter: true)
        }
        let mixes = (1...4).map { n in
            Strip(id: "mix.\(n)", name: n == 1 ? "Vocal wedge" : "Mix \(n)", style: .bus, fader: fader("mix.\(n)"),
                  buttons: [mute("mix.\(n)")], hasOutputMeter: true)
        }
        let main = Strip(id: "lr", name: "Main LR", style: .master, fader: fader("lr"),
                         buttons: [mute("lr", confirm: true)], hasOutputMeter: true)
        groups = [
            StripGroup(id: "ch", title: "Inputs", strips: inputs),
            StripGroup(id: "mix", title: "Mixes", strips: mixes),
            StripGroup(id: "lr", title: "Main", strips: [main])
        ]
        self.values = values
        self.specs = specs
        self.choices = choices
    }

    func start() {
        running = true
        sink.state(.connected)
        for (id, value) in values { sink.value(id, value) }
        sink.synced()
        meterTicker.start(every: 0.08) { [weak self] in self?.tick() }
    }

    func stop() {
        running = false
        meterTicker.stop()
        sink.state(.disconnected)
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        guard running else { return }
        if id == "scene" { return } // nothing to recall: the demo just accepts it
        guard values[id] != nil else { return }
        values[id] = value
        sink.value(id, value) // a desk reports back what it was sent
    }

    // MARK: Made-up signal

    private func number(_ id: String, default fallback: Double) -> Double {
        let cid = ControlID(id)
        if let spec = specs[cid], let position = values[cid]?.level { return spec.value(at: position) }
        if let options = choices[cid], case .number(let i)? = values[cid], options.indices.contains(i) {
            return DynamicsLayout.number(fromOption: options[i]) ?? fallback
        }
        return fallback
    }

    private func isOn(_ id: String) -> Bool { values[ControlID(id)]?.isOn ?? false }

    private func tick() {
        time += 0.08
        var readings: [String: MeterReading] = [:]
        var mixSum = Array(repeating: -120.0, count: 5) // LR, then mixes 1–4, as dB
        for n in 1...16 {
            let id = "ch.\(n)"
            // Drums hit, everything else breathes.
            let phase = time * (n <= 5 ? 2.0 + Double(n) * 0.37 : 0.6 + Double(n) * 0.05)
            let wobble = n <= 5 ? max(-30, 12 * sin(phase * .pi * 2) - 6) : 4 * sin(phase) + 2 * sin(phase * 2.3)
            var level = Self.sourceLevels[n - 1] + wobble + number("\(id).gain", default: 30) - 30
            level = min(0, level)
            let input = level
            if isOn("\(id).gate.on") {
                level = DynamicsLayout.gated(level, threshold: number("\(id).gate.thr", default: -40),
                                             range: number("\(id).gate.range", default: 40))
            }
            if isOn("\(id).comp.on") {
                level = DynamicsLayout.compressed(level, threshold: number("\(id).comp.thr", default: -18),
                                                  ratio: number("\(id).comp.ratio", default: 4),
                                                  knee: number("\(id).comp.knee", default: 4),
                                                  makeup: number("\(id).comp.makeup", default: 0))
            }
            let muted = isOn("\(id).mute")
            let fader = values[ControlID("\(id).level")]?.level.flatMap { AudioTaper.decibels(position: $0) }
            let post = muted ? nil : fader.map { min(0, level + $0) }
            readings[id] = MeterReading(input: MeterReading.position(decibels: input),
                                        output: post.map { MeterReading.position(decibels: $0) } ?? 0)
            if let post { mixSum[0] = Self.sum(mixSum[0], post) }
            for bus in 1...4 where !muted {
                if let send = values[ControlID("\(id).send.\(bus)")]?.level.flatMap({ AudioTaper.decibels(position: $0) }) {
                    mixSum[bus] = Self.sum(mixSum[bus], level + send)
                }
            }
        }
        for (i, id) in ["lr", "mix.1", "mix.2", "mix.3", "mix.4"].enumerated() {
            let fader = values[ControlID("\(id).level")]?.level.flatMap { AudioTaper.decibels(position: $0) }
            let out = isOn("\(id).mute") ? nil : fader.map { min(0, mixSum[i] - 12 + $0) }
            readings[id] = MeterReading(output: out.map { MeterReading.position(decibels: $0) } ?? 0)
        }
        sink.meters(readings)
    }

    /// Two levels added as power, in dB.
    static func sum(_ a: Double, _ b: Double) -> Double {
        10 * log10(pow(10, a / 10) + pow(10, b / 10))
    }
}

/// A lighting console that lives inside the app: ten sequences with named
/// cues on faders, a grand master and blackout, and the key panel. Go steps
/// through cues, Back steps back, Off stops, Flash holds a sequence at full.
@MainActor
final class DemoLightingDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("command", "Command", .command(hint: "Try: Fader 1 At 50, Go, Off"))
    ]
    let traits = DriverTraits(reportsChanges: true, readsNames: true,
                              note: "This is the built-in demo console: nothing leaves the app.")
    var keyPanel: KeyPanel? { LightingConsoleDriver.panel }

    static let names = ["Front wash", "Back light", "Blue wash", "Specials", "Gobos",
                        "Movers", "Strobe", "Haze", "House", "Chase"]
    static let cueNames = ["Preset", "Walk in", "Verse", "Chorus", "Bridge", "Out"]

    private var levels: [Int: Double] = [:]
    /// Running cue (index into cueNames) per sequence; nil when off.
    private var cues: [Int: Int] = [:]
    private var flashing: Set<Int> = []
    private var selected = 1
    private var master = 1.0
    private var blackout = false

    init(config: DeviceConfig, transport: TransportFactory) {
        let faders = (1...10).map { n in
            LightingConsoleDriver.playbackStrip(id: "fader.\(n)", name: "Fader \(n)", flash: true)
        }
        groups = [
            StripGroup(id: "faders", title: "Faders", strips: faders),
            StripGroup(id: "master", title: "Master", strips: [
                Strip(id: "master", name: "Grand master", style: .master,
                      fader: ControlDescriptor("master.level", "Master", .fader(.percent)),
                      buttons: [ControlDescriptor("master.blackout", "Blackout", .toggle(.blackout), needsConfirmation: true)])
            ])
        ]
    }

    func start() {
        sink.state(.connected)
        for n in 1...10 {
            sink.name("fader.\(n)", Self.names[n - 1])
            report(n)
        }
        sink.value("master.level", .level(master))
        sink.value("master.blackout", .on(blackout))
        sink.synced()
    }

    func stop() {
        sink.state(.disconnected)
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id.rawValue, value) {
        case ("master.level", .level(let v)): master = v; sink.value(id, value); return
        case ("master.blackout", .on(let on)): blackout = on; sink.value(id, value); return
        case ("command", .text(let text)): command(text); return
        default: break
        }
        if id.rawValue.hasPrefix("panel."), case .trigger = value {
            switch id.rawValue.dropFirst(6) {
            case "go": go(selected)
            case "back": back(selected)
            case "pause", "clear", "clearall", "oops", "highlight": break
            default: break
            }
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, parts[0] == "fader", let n = Int(parts[1]), (1...10).contains(n) else { return }
        selected = n
        switch (parts[2], value) {
        case ("level", .level(let v)):
            levels[n] = v
            if v > 0 && cues[n] == nil { cues[n] = 0 }
            report(n)
        case ("go", .trigger): go(n)
        case ("back", .trigger): back(n)
        case ("off", .trigger): cues[n] = nil; report(n)
        case ("pause", .trigger): break
        case ("flash", .press(let down)):
            if down { flashing.insert(n) } else { flashing.remove(n) }
            report(n)
        case ("goto", .text(let text)):
            if let cue = Int(text.trimmingCharacters(in: .whitespaces)), (1...Self.cueNames.count).contains(cue) {
                cues[n] = cue - 1
                report(n)
            }
        default:
            break
        }
    }

    // MARK: Private

    private func go(_ n: Int) {
        cues[n] = min(Self.cueNames.count - 1, (cues[n] ?? -1) + 1)
        if (levels[n] ?? 0) == 0 { levels[n] = 1 }
        report(n)
    }

    private func back(_ n: Int) {
        guard let cue = cues[n] else { return }
        cues[n] = max(0, cue - 1)
        report(n)
    }

    /// "Fader 2 At 50", "Go", "Back", "Off", "Off Fader 3".
    private func command(_ text: String) {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return }
        let number = words.compactMap(Int.init).first
        switch first {
        case "fader":
            guard let n = number, (1...10).contains(n) else { return }
            selected = n
            if let at = words.firstIndex(of: "at"), at + 1 < words.count {
                let level = words[at + 1] == "full" ? 100 : Double(words[at + 1]) ?? 0
                levels[n] = min(100, max(0, level)) / 100
                sink.value(ControlID("fader.\(n).level"), .level(levels[n]!))
                if levels[n]! > 0 && cues[n] == nil { cues[n] = 0 }
                report(n)
            }
        case "go": go(number ?? selected)
        case "back": back(number ?? selected)
        case "off":
            let n = number ?? selected
            cues[n] = nil
            report(n)
        default:
            break
        }
    }

    private func report(_ n: Int) {
        let id = "fader.\(n)"
        sink.value(ControlID("\(id).level"), .level(levels[n] ?? 0))
        let cue = cues[n]
        sink.info("\(id).cue", cue.map { "\($0 + 1) \(Self.cueNames[$0])" })
        let next = (cue ?? -1) + 1
        sink.info("\(id).next", next < Self.cueNames.count ? "\(next + 1) \(Self.cueNames[next])" : nil)
        sink.info("\(id).active", cue != nil || flashing.contains(n) ? "1" : nil)
    }
}
