import Foundation

/// Yamaha TF, DM3, CL/QL and DM7 over RCP: text lines on TCP 49280.
///
///     set MIXER:Current/InCh/Fader/Level 0 0 -1000      → channel 1 to −10 dB
///     OK set MIXER:Current/InCh/Fader/Level 0 0 -1000   ← confirmation
///     NOTIFY set MIXER:Current/InCh/Fader/Level 0 0 -1000 "-10.00"  ← changed elsewhere
///
/// Channels are zero-based. Levels are dB × 100 (−13800…1000), −32768 is −∞.
/// `Fader/On` is 1 when the channel is on (unmuted). Paths and counts come from
/// the consoles' own parameter lists (`prminfo`), as published with the
/// Bitfocus Companion Yamaha RCP module.
@MainActor
final class YamahaRCPDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    private struct Kind {
        let path: String // e.g. "InCh"
        let title: String
        let short: String
        let count: Int
        let style: StripStyle
    }

    private static func kinds(for variant: String) -> [Kind] {
        switch variant {
        case "dm3":
            return [
                Kind(path: "InCh", title: "Inputs", short: "Ch", count: 16, style: .input),
                Kind(path: "StInCh", title: "Stereo Inputs", short: "ST In", count: 2, style: .input),
                Kind(path: "FxRtnCh", title: "FX Returns", short: "FX Rtn", count: 4, style: .fx),
                Kind(path: "Mix", title: "Mixes", short: "Mix", count: 6, style: .bus),
                Kind(path: "Mtrx", title: "Matrices", short: "Mtx", count: 2, style: .bus),
                Kind(path: "St", title: "Stereo", short: "Stereo", count: 1, style: .master)
            ]
        case "clql":
            return [
                Kind(path: "InCh", title: "Inputs", short: "Ch", count: 72, style: .input),
                Kind(path: "StInCh", title: "Stereo Inputs", short: "ST In", count: 8, style: .input),
                Kind(path: "Mix", title: "Mixes", short: "Mix", count: 24, style: .bus),
                Kind(path: "Mtrx", title: "Matrices", short: "Mtx", count: 8, style: .bus),
                Kind(path: "DCA", title: "DCAs", short: "DCA", count: 16, style: .dca),
                Kind(path: "St", title: "Stereo", short: "Stereo", count: 1, style: .master)
            ]
        case "dm7":
            return [
                Kind(path: "InCh", title: "Inputs", short: "Ch", count: 120, style: .input),
                Kind(path: "Mix", title: "Mixes", short: "Mix", count: 48, style: .bus),
                Kind(path: "Mtrx", title: "Matrices", short: "Mtx", count: 12, style: .bus),
                Kind(path: "DCA", title: "DCAs", short: "DCA", count: 24, style: .dca),
                Kind(path: "St", title: "Stereo", short: "Stereo", count: 1, style: .master)
            ]
        default: // TF
            return [
                Kind(path: "InCh", title: "Inputs", short: "Ch", count: 40, style: .input),
                Kind(path: "StInCh", title: "Stereo Inputs", short: "ST In", count: 4, style: .input),
                Kind(path: "FxRtnCh", title: "FX Returns", short: "FX Rtn", count: 4, style: .fx),
                Kind(path: "Mix", title: "Aux Mixes", short: "Aux", count: 20, style: .bus),
                Kind(path: "Mtrx", title: "Matrices", short: "Mtx", count: 4, style: .bus),
                Kind(path: "DCA", title: "DCAs", short: "DCA", count: 8, style: .dca),
                Kind(path: "St", title: "Main", short: "Stereo", count: 1, style: .master),
                Kind(path: "Mono", title: "Main", short: "Mono", count: 1, style: .master)
            ]
        }
    }

    static func wireLevel(decibels: Double?) -> Int {
        guard let db = decibels, db > -138 else { return -32768 }
        return Int((min(10, db) * 100).rounded())
    }

    static func decibels(wire: Int) -> Double? {
        wire <= -13800 ? nil : Double(wire) / 100
    }

    private enum Param: Hashable {
        case level, on, name
        var suffix: String {
            switch self {
            case .level: return "Fader/Level"
            case .on: return "Fader/On"
            case .name: return "Label/Name"
            }
        }
    }

    private let variant: String
    private let transport: Transport
    private var lines = LineSplitter()
    private let pacer = QueryPacer()
    private let keepalive = Ticker()
    private var answered = false
    private var lastHeard = ContinuousClock.now
    /// "InCh 0" -> strip id
    private var stripByAddress: [String: String] = [:]
    /// strip id -> ("InCh", 0)
    private var addressByStrip: [String: (String, Int)] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        variant = config.variant
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))

        var stripByAddress: [String: String] = [:]
        var addressByStrip: [String: (String, Int)] = [:]
        var grouped: [(String, [Strip])] = []
        for kind in Self.kinds(for: config.variant) {
            let strips = (0..<kind.count).map { x -> Strip in
                let id = kind.count == 1 ? kind.path.lowercased() : "\(kind.path.lowercased()).\(x + 1)"
                stripByAddress["\(kind.path) \(x)"] = id
                addressByStrip[id] = (kind.path, x)
                return Strip(
                    id: id, name: kind.count == 1 ? kind.short : "\(kind.short) \(x + 1)", style: kind.style,
                    fader: ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.decibels)),
                    buttons: [ControlDescriptor(ControlID("\(id).mute"), "Mute", .toggle(.mute), needsConfirmation: kind.style == .master)]
                )
            }
            // Kinds sharing a title (TF's Stereo and Mono) share a group.
            if let i = grouped.firstIndex(where: { $0.0 == kind.title }) {
                grouped[i].1 += strips
            } else {
                grouped.append((kind.title, strips))
            }
        }
        groups = grouped.map { StripGroup(id: $0.0, title: $0.0, strips: $0.1) }
        self.stripByAddress = stripByAddress
        self.addressByStrip = addressByStrip

        switch config.variant {
        case "clql":
            deviceControls = [ControlDescriptor("scene", "Recall scene", .number(0...300), needsConfirmation: true)]
        case "tf", "dm3":
            deviceControls = [ControlDescriptor("scene", "Recall scene (bank A)", .number(0...99), needsConfirmation: true)]
        default:
            deviceControls = [] // DM7 scene recall uses text scene numbers; not supported yet
        }

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        lines = LineSplitter()
        answered = false
        transport.open()
    }

    func stop() {
        pacer.stop()
        keepalive.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        if id == "scene", case .number(let scene) = value {
            switch variant {
            case "clql": line("ssrecall_ex MIXER:Lib/Scene \(scene)")
            case "tf", "dm3": line("ssrecall_ex scene_a \(scene)")
            default: break
            }
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard let last = parts.last, case let (path, x)? = addressByStrip[parts.dropLast().joined(separator: ".")] else { return }
        switch (last, value) {
        case ("level", .level(let position)):
            line("set MIXER:Current/\(path)/Fader/Level \(x) 0 \(Self.wireLevel(decibels: AudioTaper.decibels(position: position)))")
        case ("mute", .on(let muted)):
            line("set MIXER:Current/\(path)/Fader/On \(x) 0 \(muted ? 0 : 1)")
        default:
            break
        }
    }

    // MARK: Private

    private func line(_ text: String) {
        transport.send(Data((text + "\n").utf8))
    }

    private func transportState(_ state: TransportState) {
        guard state == .ready else {
            pacer.stop()
            keepalive.stop()
            sink.state(state.linkState)
            return
        }
        sink.state(.connecting)
        lastHeard = .now
        // Ask something with an answer; the first answer means the console is there.
        keepalive.start(every: 5, immediately: true) { [weak self] in
            guard let self else { return }
            if ContinuousClock.now - self.lastHeard > .seconds(15) {
                self.keepalive.stop()
                self.sink.state(.failed(self.answered ? "The console stopped answering" : "No answer from the console"))
                return
            }
            self.line("devstatus runmode")
        }
    }

    private func readEverything() {
        var queries: [Data] = []
        for entry in addressByStrip.sorted(by: { $0.key < $1.key }) {
            let (path, x) = entry.value
            for param in [Param.level, .on, .name] {
                queries.append(Data("get MIXER:Current/\(path)/\(param.suffix) \(x) 0\n".utf8))
            }
        }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.sink.synced()
            }
        }
    }

    private func receive(_ data: Data) {
        for text in lines.feed(data) {
            let words = splitWords(text)
            guard words.count >= 2, ["OK", "OKM", "NOTIFY"].contains(words[0].uppercased()) else { continue }
            lastHeard = .now
            if !answered {
                answered = true
                sink.state(.connected)
                readEverything()
            }
            guard ["get", "set"].contains(words[1]), words.count >= 6, let x = Int(words[3]) else { continue }
            let path = words[2]
            guard path.hasPrefix("MIXER:Current/") else { continue }
            let rest = path.dropFirst("MIXER:Current/".count).split(separator: "/", maxSplits: 1)
            guard rest.count == 2, let id = stripByAddress["\(rest[0]) \(x)"] else { continue }
            let value = words[5]
            switch rest[1] {
            case "Fader/Level":
                if let wire = Int(value) {
                    sink.value(ControlID("\(id).level"), .level(AudioTaper.position(decibels: Self.decibels(wire: wire))))
                }
            case "Fader/On":
                if let on = Int(value) { sink.value(ControlID("\(id).mute"), .on(on == 0)) }
            case "Label/Name":
                sink.name(id, value)
            default:
                break
            }
        }
    }
}
