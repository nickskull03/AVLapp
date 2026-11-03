import Foundation

/// Behringer X32/M32 (UDP 10023) and X Air/MR (UDP 10024), over OSC.
///
/// - Fader values are 0–1 floats on the X32 law, which is `AudioTaper`, so
///   they pass straight through.
/// - `…/mix/on` is 1 when the channel is *on* (unmuted).
/// - A query is the address with no arguments; the mixer answers with the value.
/// - The mixer only reports changes made elsewhere for ~10 s after each
///   `/xremote`, so that's renewed every few seconds. Meters work the same way
///   with `/meters`.
/// - Processing values are also 0–1 floats, each on its own linear or log
///   range. Every `ParameterSpec` here uses the mixer's own range and curve,
///   so a position is the wire value. Ranges are from Patrick-Gilles Maillot's
///   unofficial X32 OSC protocol document.
@MainActor
final class BehringerDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    private enum Target {
        case fader(ControlID)
        case onSwitch(ControlID) // 1 = on, so muted = 0
        case muteSwitch(ControlID) // 1 = muted (mute groups)
        case name(String)
        case parameter(ControlID) // a 0–1 float
        case choice(ControlID) // an int index
        case enable(ControlID) // 1 = on
    }

    // Processing ranges, as the mixer has them.
    static let gainSpec = ParameterSpec(-12, 60, unit: "dB")
    static let hpfSpec = ParameterSpec(20, 400, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let eqFreqSpec = ParameterSpec(20, 20000, unit: "Hz", curve: .logarithmic, decimals: 0)
    static let eqGainSpec = ParameterSpec(-15, 15, unit: "dB")
    static let eqQSpec = ParameterSpec(10, 0.3, curve: .logarithmic)
    static let gateThresholdSpec = ParameterSpec(-80, 0, unit: "dB")
    static let gateRangeSpec = ParameterSpec(3, 60, unit: "dB")
    static let attackSpec = ParameterSpec(0, 120, unit: "ms", decimals: 0)
    static let holdSpec = ParameterSpec(0.02, 2000, unit: "ms", curve: .logarithmic, decimals: 2)
    static let releaseSpec = ParameterSpec(5, 4000, unit: "ms", curve: .logarithmic, decimals: 0)
    static let compThresholdSpec = ParameterSpec(-60, 0, unit: "dB")
    static let makeupSpec = ParameterSpec(0, 24, unit: "dB")
    static let ratios = ["1.1:1", "1.3:1", "1.5:1", "2:1", "2.5:1", "3:1", "4:1", "5:1", "7:1", "10:1", "20:1", "100:1"]

    private let config: DeviceConfig
    private let isX32: Bool
    private let transport: Transport
    private var targets: [String: Target] = [:] // OSC address -> what it is
    private var addresses: [ControlID: String] = [:]
    /// Strip ID -> its processing addresses, read when its detail opens.
    private var detailQueries: [String: [String]] = [:]
    private let heartbeat = Ticker()
    private let pacer = QueryPacer()
    private var lastHeard: ContinuousClock.Instant?
    private var answered = false
    private var openedAt: ContinuousClock.Instant = .now

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        self.config = config
        let x32 = config.kind == .behringerX32
        isX32 = x32
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: nil))

        var groups: [StripGroup] = []
        var targets: [String: Target] = [:]
        var addresses: [ControlID: String] = [:]
        var detailQueries: [String: [String]] = [:]

        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        func three(_ n: Int) -> String { n < 10 ? "00\(n)" : n < 100 ? "0\(n)" : "\(n)" }

        func parameter(_ id: ControlID, _ address: String, _ label: String, _ spec: ParameterSpec) -> ControlDescriptor {
            targets[address] = .parameter(id)
            addresses[id] = address
            return ControlDescriptor(id, label, .parameter(spec))
        }

        func enable(_ id: ControlID, _ address: String, _ label: String) -> ControlDescriptor {
            targets[address] = .enable(id)
            addresses[id] = address
            return ControlDescriptor(id, label, .toggle(.enable))
        }

        // A strip with a fader at `<base>/mix/fader`, on at `<base>/mix/on`
        // (or `<base>/fader` and `<base>/on` for DCAs), name at `<base>/config/name`.
        // Input channels also get preamp gain and processing.
        func strip(_ base: String, _ name: String, _ style: StripStyle, mixPath: Bool = true,
                   confirmMute: Bool = false, headamp: String? = nil, processing: Bool = false,
                   inputMeter: Bool = false, outputMeter: Bool = false) -> Strip {
            let id = String(base.dropFirst())
            let levelID = ControlID("\(id).level")
            let muteID = ControlID("\(id).mute")
            let fader = mixPath ? "\(base)/mix/fader" : "\(base)/fader"
            let on = mixPath ? "\(base)/mix/on" : "\(base)/on"
            targets[fader] = .fader(levelID)
            targets[on] = .onSwitch(muteID)
            targets["\(base)/config/name"] = .name(id)
            addresses[levelID] = fader
            addresses[muteID] = on

            var gain: ControlDescriptor? = nil
            if let headamp {
                gain = parameter(ControlID("\(id).gain"), headamp, "Gain", Self.gainSpec)
            }
            var sections: [ControlSection] = []
            if processing {
                let before = Set(addresses.values)
                sections.append(ControlSection(id: "hpf", title: "High-pass", controls: [
                    enable(ControlID("\(id).hpf.on"), "\(base)/preamp/hpon", "High-pass on"),
                    parameter(ControlID("\(id).hpf.freq"), "\(base)/preamp/hpf", "Frequency", Self.hpfSpec)
                ]))
                var eq = [enable(ControlID("\(id).eq.on"), "\(base)/eq/on", "EQ on")]
                for band in 1...4 {
                    eq += [
                        parameter(ControlID("\(id).eq.\(band).freq"), "\(base)/eq/\(band)/f", "Band \(band) frequency", Self.eqFreqSpec),
                        parameter(ControlID("\(id).eq.\(band).gain"), "\(base)/eq/\(band)/g", "Band \(band) gain", Self.eqGainSpec),
                        parameter(ControlID("\(id).eq.\(band).q"), "\(base)/eq/\(band)/q", "Band \(band) Q", Self.eqQSpec)
                    ]
                }
                sections.append(ControlSection(id: "eq", title: "EQ", controls: eq))
                sections.append(ControlSection(id: "gate", title: "Gate", controls: [
                    enable(ControlID("\(id).gate.on"), "\(base)/gate/on", "Gate on"),
                    parameter(ControlID("\(id).gate.thr"), "\(base)/gate/thr", "Threshold", Self.gateThresholdSpec),
                    parameter(ControlID("\(id).gate.range"), "\(base)/gate/range", "Range", Self.gateRangeSpec),
                    parameter(ControlID("\(id).gate.attack"), "\(base)/gate/attack", "Attack", Self.attackSpec),
                    parameter(ControlID("\(id).gate.hold"), "\(base)/gate/hold", "Hold", Self.holdSpec),
                    parameter(ControlID("\(id).gate.release"), "\(base)/gate/release", "Release", Self.releaseSpec)
                ]))
                let ratioID = ControlID("\(id).comp.ratio")
                targets["\(base)/dyn/ratio"] = .choice(ratioID)
                addresses[ratioID] = "\(base)/dyn/ratio"
                sections.append(ControlSection(id: "comp", title: "Compressor", controls: [
                    enable(ControlID("\(id).comp.on"), "\(base)/dyn/on", "Compressor on"),
                    parameter(ControlID("\(id).comp.thr"), "\(base)/dyn/thr", "Threshold", Self.compThresholdSpec),
                    ControlDescriptor(ratioID, "Ratio", .choice(Self.ratios)),
                    parameter(ControlID("\(id).comp.attack"), "\(base)/dyn/attack", "Attack", Self.attackSpec),
                    parameter(ControlID("\(id).comp.release"), "\(base)/dyn/release", "Release", Self.releaseSpec),
                    parameter(ControlID("\(id).comp.makeup"), "\(base)/dyn/mgain", "Make-up gain", Self.makeupSpec)
                ]))
                detailQueries[id] = Array(Set(addresses.values).subtracting(before)).sorted()
            }
            return Strip(
                id: id, name: name, style: style,
                fader: ControlDescriptor(levelID, "Fader", .fader(.decibels)),
                buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute), needsConfirmation: confirmMute)],
                gain: gain, sections: sections,
                hasInputMeter: inputMeter, hasOutputMeter: outputMeter
            )
        }

        func muteGroups(_ count: Int) -> StripGroup {
            StripGroup(id: "mutegroups", title: "Mute Groups", strips: (1...count).map { n in
                let path = "/config/mute/\(n)"
                let muteID = ControlID("mutegroup.\(n).mute")
                targets[path] = .muteSwitch(muteID)
                addresses[muteID] = path
                return Strip(id: "mutegroup.\(n)", name: "Mute \(n)", style: .muteGroup, fader: nil,
                             buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute))])
            })
        }

        if x32 {
            // Preamp gain assumes channel n is on local input n (the X32 default).
            let inputs = (1...32).map { n in
                strip("/ch/\(two(n))", "Ch \(n)", .input, headamp: "/headamp/\(three(n - 1))/gain",
                      processing: true, inputMeter: true)
            }
            groups = [
                StripGroup(id: "ch", title: "Inputs", strips: inputs),
                StripGroup(id: "auxin", title: "Aux Ins", strips: (1...8).map { strip("/auxin/\(two($0))", "Aux \($0)", .input) }),
                StripGroup(id: "fxrtn", title: "FX Returns", strips: (1...8).map { strip("/fxrtn/\(two($0))", "FX \($0)", .fx) }),
                StripGroup(id: "bus", title: "Mix Buses", strips: (1...16).map { strip("/bus/\(two($0))", "Bus \($0)", .bus) }),
                StripGroup(id: "mtx", title: "Matrices", strips: (1...6).map { strip("/mtx/\(two($0))", "Mtx \($0)", .bus) }),
                StripGroup(id: "dca", title: "DCAs", strips: (1...8).map { strip("/dca/\($0)", "DCA \($0)", .dca, mixPath: false) }),
                StripGroup(id: "main", title: "Mains", strips: [
                    strip("/main/st", "Main LR", .master, confirmMute: true),
                    strip("/main/m", "Mono", .master, confirmMute: true)
                ]),
                muteGroups(6)
            ]
        } else {
            let inputs = (1...16).map { n in
                strip("/ch/\(two(n))", "Ch \(n)", .input, headamp: "/headamp/\(two(n))/gain", processing: true, inputMeter: true)
            }
            groups = [
                StripGroup(id: "ch", title: "Inputs", strips: inputs + [strip("/rtn/aux", "Aux In", .input, inputMeter: true)]),
                StripGroup(id: "rtn", title: "FX Returns", strips: (1...4).map { strip("/rtn/\($0)", "FX \($0)", .fx, inputMeter: true) }),
                StripGroup(id: "bus", title: "Buses", strips: (1...6).map { strip("/bus/\($0)", "Bus \($0)", .bus, outputMeter: true) }
                    + (1...4).map { strip("/fxsend/\($0)", "FX Send \($0)", .fx, outputMeter: true) }),
                StripGroup(id: "dca", title: "DCAs", strips: (1...4).map { strip("/dca/\($0)", "DCA \($0)", .dca, mixPath: false) }),
                StripGroup(id: "main", title: "Main", strips: [strip("/lr", "Main LR", .master, confirmMute: true, outputMeter: true)]),
                muteGroups(4)
            ]
        }
        self.groups = groups
        self.targets = targets
        self.addresses = addresses
        self.detailQueries = detailQueries
        deviceControls = [
            x32
                ? ControlDescriptor("scene", "Recall scene", .number(0...99), needsConfirmation: true)
                : ControlDescriptor("scene", "Load snapshot", .number(1...64), needsConfirmation: true)
        ]

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
            transport.send(OSCMessage(isX32 ? "/-action/goscene" : "/-snap/load", [.int(Int32(n))]).encoded())
            return
        }
        guard let address = addresses[id], let target = targets[address] else { return }
        switch (target, value) {
        case (.fader, .level(let position)), (.parameter, .level(let position)):
            transport.send(OSCMessage(address, [.float(Float(clamp01(position)))]).encoded())
        case (.onSwitch, .on(let muted)):
            transport.send(OSCMessage(address, [.int(muted ? 0 : 1)]).encoded())
        case (.muteSwitch, .on(let muted)), (.enable, .on(let muted)):
            transport.send(OSCMessage(address, [.int(muted ? 1 : 0)]).encoded())
        case (.choice, .number(let index)):
            transport.send(OSCMessage(address, [.int(Int32(index))]).encoded())
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

    private func transportState(_ state: TransportState) {
        sink.state(state.linkState)
        guard state == .ready else {
            heartbeat.stop()
            return
        }
        // UDP is "ready" at once; the mixer is only there once it answers.
        openedAt = .now
        heartbeat.start(every: 4, immediately: true) { [weak self] in self?.pulse() }
    }

    private func pulse() {
        transport.send(OSCMessage("/xremote").encoded())
        transport.send(OSCMessage("/xinfo").encoded())
        // Renew the meter subscription (it lapses after ~10 s, like /xremote).
        transport.send(OSCMessage("/meters", [.string("/meters/1"), .int(0)]).encoded())
        let now = ContinuousClock.now
        if let lastHeard {
            if now - lastHeard > .seconds(10) {
                heartbeat.stop()
                sink.state(.failed("The mixer stopped answering"))
            }
        } else if now - openedAt > .seconds(7) {
            heartbeat.stop()
            sink.state(.failed("No answer from \(config.trimmedHost):\(config.port)"))
        }
    }

    private func receive(_ data: Data) {
        lastHeard = .now
        if !answered {
            answered = true
            sink.state(.connected)
            readEverything()
        }
        for message in OSCMessage.decode(data) {
            if message.address == "/meters/1", case .blob(let blob)? = message.arguments.first {
                if let readings = Self.meterReadings(blob, x32: isX32) { sink.meters(readings) }
                continue
            }
            guard let target = targets[message.address], let argument = message.arguments.first else { continue }
            switch target {
            case .fader(let id), .parameter(let id):
                if let v = argument.number { sink.value(id, .level(clamp01(v))) }
            case .onSwitch(let id):
                if let v = argument.number { sink.value(id, .on(v < 0.5)) }
            case .muteSwitch(let id), .enable(let id):
                if let v = argument.number { sink.value(id, .on(v >= 0.5)) }
            case .choice(let id):
                if let v = argument.number { sink.value(id, .number(Int(v))) }
            case .name(let stripID):
                if let name = argument.string { sink.name(stripID, name) }
            }
        }
    }

    /// Strip levels, faders, mutes and names: what the strips show. Processing
    /// is read when a strip's detail opens, so connecting stays quick.
    private func readEverything() {
        let processing = Set(detailQueries.values.joined())
        let queries = targets.keys.filter { !processing.contains($0) || $0.hasPrefix("/headamp/") }
            .sorted()
            .map { OSCMessage($0).encoded() }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            // Give the last answers a moment to arrive.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.sink.synced()
            }
        }
    }

    /// `/meters/1` is a blob: a little-endian count, then that many values.
    /// X Air sends 16-bit values in 1/256 dB (40 of them: channels 1–16, aux
    /// in L/R, FX returns 1–4 L/R, buses 1–6, FX sends 1–4, main L/R, monitor
    /// L/R). The X32 sends 32-bit floats, linear, with channels 1–32 first.
    static func meterReadings(_ blob: Data, x32: Bool) -> [String: MeterReading]? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let count = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var levels: [Double] = [] // meter positions
        if bytes.count >= 4 + count * 4, x32 {
            for i in 0..<count {
                let o = 4 + i * 4
                let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                levels.append(MeterReading.position(amplitude: Double(Float(bitPattern: bits))))
            }
        } else if bytes.count >= 4 + count * 2 {
            for i in 0..<count {
                let o = 4 + i * 2
                let raw = Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)
                levels.append(MeterReading.position(decibels: Double(raw) / 256))
            }
        } else {
            return nil
        }

        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        var readings: [String: MeterReading] = [:]
        if x32 {
            for i in 0..<min(32, levels.count) { readings["ch/\(two(i + 1))"] = MeterReading(input: levels[i]) }
            return readings
        }
        guard levels.count >= 38 else { return nil }
        for i in 0..<16 { readings["ch/\(two(i + 1))"] = MeterReading(input: levels[i]) }
        readings["rtn/aux"] = MeterReading(input: max(levels[16], levels[17]))
        for i in 0..<4 { readings["rtn/\(i + 1)"] = MeterReading(input: max(levels[18 + i * 2], levels[19 + i * 2])) }
        for i in 0..<6 { readings["bus/\(i + 1)"] = MeterReading(output: levels[26 + i]) }
        for i in 0..<4 { readings["fxsend/\(i + 1)"] = MeterReading(output: levels[32 + i]) }
        readings["lr"] = MeterReading(output: max(levels[36], levels[37]))
        return readings
    }
}
