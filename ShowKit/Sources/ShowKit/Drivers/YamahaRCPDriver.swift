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
///
/// Processing differs between console families (names, ranges, scales), so
/// after connecting the driver asks the console for its parameter list
/// (`prminfo 0`, `prminfo 1`, …) and builds gain, high-pass, EQ and dynamics
/// controls from whatever the console says it has. Meters come from
/// `mtrstart <path> <ms>`, answered by `NOTIFY mtr <path> <type> <hex values…>`.
@MainActor
final class YamahaRCPDriver: ConsoleDriver {
    let sink = DriverSink()
    private(set) var groups: [StripGroup]
    let deviceControls: [ControlDescriptor]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    private struct Kind {
        let path: String // e.g. "InCh"
        let title: String
        let short: String
        let count: Int
        let style: StripStyle

        var isInput: Bool { style == .input || style == .fx }
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

    /// One processing parameter as the console described it in `prminfo`.
    struct ParameterInfo: Equatable {
        let path: String
        let xCount: Int
        let yCount: Int
        let min: Int
        let max: Int
        let unit: String
        let scale: Int

        /// Parses `OK prminfo <index> "<path>" <x> <y> <min> <max> <default> "<unit>" <type> <ui> <rw> <scale>`.
        init?(words: [String]) {
            guard words.count >= 14, words[1] == "prminfo", words[10] == "integer", words[12].contains("w"),
                  let x = Int(words[4]), let y = Int(words[5]), let min = Int(words[6]), let max = Int(words[7]),
                  let scale = Int(words[13]), scale > 0, min < max else { return nil }
            path = words[3]
            xCount = x
            yCount = y
            self.min = min
            self.max = max
            unit = words[9]
            self.scale = scale
        }

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var isSwitch: Bool { min == 0 && max == 1 }

        var spec: ParameterSpec {
            let lo = Double(min) / Double(scale)
            let hi = Double(max) / Double(scale)
            let lower = name.lowercased()
            var unit = self.unit
            if unit.isEmpty {
                if lower.contains("freq") { unit = "Hz" }
                else if lower.contains("gain") || lower.contains("threshold") || lower.contains("range") { unit = "dB" }
            }
            let logarithmic = unit == "Hz" || (lo > 0 && hi / lo >= 50)
            let decimals = scale >= 1000 ? 2 : scale >= 10 ? 1 : 0
            return ParameterSpec(lo, hi, unit: unit, curve: logarithmic ? .logarithmic : .linear, decimals: decimals)
        }

        func raw(at position: Double) -> Int {
            let value = (spec.value(at: position) * Double(scale)).rounded()
            return Swift.min(max, Swift.max(min, Int(value)))
        }

        func position(raw: Int) -> Double {
            spec.position(for: Double(raw) / Double(scale))
        }
    }

    /// Which section a processing path belongs in, or nil to leave it out.
    static func section(for path: String, kind: String) -> (id: String, title: String)? {
        if path == "IO:Current/\(kind)/HAGain" || path == "MIXER:Current/\(kind)/Port/HA/Gain" { return ("gain", "Gain") }
        let prefix = "MIXER:Current/\(kind)/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        let first = rest.split(separator: "/").first.map { $0.lowercased() } ?? ""
        let name = rest.split(separator: "/").last.map { $0.lowercased() } ?? ""
        if ["bypass", "bankselect", "type", "mixbalance", "recovery"].contains(name) { return nil }
        switch first {
        case "hpf": return ("hpf", "High-pass")
        case "peq", "eq": return ("eq", "EQ")
        case "dyna1", "gate": return ("gate", "Gate")
        case "dyna2", "comp": return ("comp", "Compressor")
        default: return nil
        }
    }

    private struct Binding {
        let info: ParameterInfo
        let y: Int
    }

    private let variant: String
    private let transport: Transport
    private var lines = LineSplitter()
    private let pacer = QueryPacer()
    private let discovery = QueryPacer(perTick: 30, interval: 0.03)
    private let keepalive = Ticker()
    private let meterRenewal = Ticker()
    private var answered = false
    private var lastHeard = ContinuousClock.now
    private let kinds: [Kind]
    /// "InCh 0" -> strip id
    private var stripByAddress: [String: String] = [:]
    /// strip id -> ("InCh", 0)
    private var addressByStrip: [String: (String, Int)] = [:]
    /// Parameters the console reported, by path.
    private var discovered: [String: ParameterInfo] = [:]
    /// Control ID -> the parameter and band (y) behind it.
    private var bindings: [ControlID: Binding] = [:]
    /// "path y" -> its control's suffix, e.g. "eq.Band.Freq.0".
    private var suffixByPathAndY: [String: String] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        variant = config.variant
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))
        let kinds = Self.kinds(for: config.variant)
        self.kinds = kinds

        var stripByAddress: [String: String] = [:]
        var addressByStrip: [String: (String, Int)] = [:]
        for kind in kinds {
            for x in 0..<kind.count {
                let id = Self.stripID(kind, x)
                stripByAddress["\(kind.path) \(x)"] = id
                addressByStrip[id] = (kind.path, x)
            }
        }
        self.stripByAddress = stripByAddress
        self.addressByStrip = addressByStrip
        groups = Self.buildGroups(kinds: kinds, processing: [:])

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

    private static func stripID(_ kind: Kind, _ x: Int) -> String {
        kind.count == 1 ? kind.path.lowercased() : "\(kind.path.lowercased()).\(x + 1)"
    }

    /// Strips, with gain and processing sections for the kinds the console reported them for.
    private static func buildGroups(kinds: [Kind], processing: [String: [(id: String, title: String, params: [ParameterInfo])]]) -> [StripGroup] {
        var grouped: [(String, [Strip])] = []
        for kind in kinds {
            let found = processing[kind.path] ?? []
            let strips = (0..<kind.count).map { x -> Strip in
                let id = stripID(kind, x)
                var gain: ControlDescriptor? = nil
                var sections: [ControlSection] = []
                for section in found {
                    let controls = section.params.flatMap { info in controlsFor(info, strip: id, section: section.id) }
                    if section.id == "gain" {
                        gain = controls.first.map { ControlDescriptor($0.id, "Gain", $0.kind) }
                    } else if !controls.isEmpty {
                        sections.append(ControlSection(id: section.id, title: section.title, controls: controls))
                    }
                }
                return Strip(
                    id: id, name: kind.count == 1 ? kind.short : "\(kind.short) \(x + 1)", style: kind.style,
                    fader: ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.decibels)),
                    buttons: [ControlDescriptor(ControlID("\(id).mute"), "Mute", .toggle(.mute), needsConfirmation: kind.style == .master)],
                    gain: gain, sections: sections,
                    hasInputMeter: kind.isInput, hasOutputMeter: true
                )
            }
            // Kinds sharing a title (TF's Stereo and Mono) share a group.
            if let i = grouped.firstIndex(where: { $0.0 == kind.title }) {
                grouped[i].1 += strips
            } else {
                grouped.append((kind.title, strips))
            }
        }
        return grouped.map { StripGroup(id: $0.0, title: $0.0, strips: $0.1) }
    }

    static func suffix(_ info: ParameterInfo, section: String, y: Int) -> String {
        let after = info.path.split(separator: "/").suffix(2).joined(separator: ".")
        return "\(section).\(after).\(y)"
    }

    private static func controlsFor(_ info: ParameterInfo, strip id: String, section: String) -> [ControlDescriptor] {
        (0..<max(1, info.yCount)).map { y in
            let controlID = ControlID("\(id).\(suffix(info, section: section, y: y))")
            var label = info.name == "On" ? "On" : info.name.replacingOccurrences(of: "Freq", with: "Frequency")
            if info.yCount > 1 { label = "Band \(y + 1) \(label.lowercased())" }
            if info.isSwitch { return ControlDescriptor(controlID, label, .toggle(.enable)) }
            return ControlDescriptor(controlID, label, .parameter(info.spec))
        }
    }

    func start() {
        lines = LineSplitter()
        answered = false
        transport.open()
    }

    func stop() {
        pacer.stop()
        discovery.stop()
        keepalive.stop()
        meterRenewal.stop()
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
        if let binding = bindings[id], case let (_, x)? = addressByStrip[stripOf(id)] {
            switch value {
            case .level(let position): line("set \(binding.info.path) \(x) \(binding.y) \(binding.info.raw(at: position))")
            case .on(let on): line("set \(binding.info.path) \(x) \(binding.y) \(on ? 1 : 0)")
            default: break
            }
            return
        }
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

    func detailOpened(_ stripID: String) {
        guard case let (_, x)? = addressByStrip[stripID] else { return }
        for (id, binding) in bindings where stripOf(id) == stripID {
            line("get \(binding.info.path) \(x) \(binding.y)")
        }
    }

    // MARK: Private

    /// "inch.3.eq.Band.Freq.0" -> "inch.3"
    private func stripOf(_ id: ControlID) -> String {
        let parts = id.rawValue.split(separator: ".")
        // Strip IDs are one word ("st") or a word and a number ("inch.3").
        if parts.count > 1, Int(parts[1]) != nil { return "\(parts[0]).\(parts[1])" }
        return String(parts.first ?? "")
    }

    private func line(_ text: String) {
        transport.send(Data((text + "\n").utf8))
    }

    private func transportState(_ state: TransportState) {
        guard state == .ready else {
            pacer.stop()
            discovery.stop()
            keepalive.stop()
            meterRenewal.stop()
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
            for suffix in ["Fader/Level", "Fader/On", "Label/Name"] {
                queries.append(Data("get MIXER:Current/\(path)/\(suffix) \(x) 0\n".utf8))
            }
        }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                self.sink.synced()
                self.discoverProcessing()
                self.startMeters()
            }
        }
    }

    /// Asks for the console's parameter list, then builds processing controls from it.
    private func discoverProcessing() {
        let queries = (0..<3000).map { Data("prminfo \($0)\n".utf8) }
        discovery.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.buildProcessing()
            }
        }
    }

    func buildProcessing() {
        var processing: [String: [(id: String, title: String, params: [ParameterInfo])]] = [:]
        var bindings: [ControlID: Binding] = [:]
        var suffixByPathAndY: [String: String] = [:]
        let order = ["gain", "hpf", "eq", "gate", "comp"]
        for kind in kinds where kind.isInput {
            var sections: [String: (title: String, params: [ParameterInfo])] = [:]
            for info in discovered.values.sorted(by: { $0.path < $1.path }) {
                guard let section = Self.section(for: info.path, kind: kind.path) else { continue }
                sections[section.id, default: (section.title, [])].params.append(info)
            }
            let list = order.compactMap { id in sections[id].map { (id: id, title: $0.title, params: $0.params) } }
            guard !list.isEmpty else { continue }
            processing[kind.path] = list
            for x in 0..<kind.count {
                let stripID = Self.stripID(kind, x)
                for section in list {
                    for info in section.params {
                        for y in 0..<max(1, info.yCount) {
                            let suffix = Self.suffix(info, section: section.id, y: y)
                            bindings[ControlID("\(stripID).\(suffix)")] = Binding(info: info, y: y)
                            suffixByPathAndY["\(info.path) \(y)"] = suffix
                        }
                    }
                }
            }
        }
        guard !processing.isEmpty else { return }
        self.bindings = bindings
        self.suffixByPathAndY = suffixByPathAndY
        groups = Self.buildGroups(kinds: kinds, processing: processing)
        sink.layoutChanged()
        // Read gain for every strip that has it: it's on the strip itself.
        for (id, binding) in bindings where id.rawValue.contains(".gain.") {
            if case let (_, x)? = addressByStrip[stripOf(id)] {
                line("get \(binding.info.path) \(x) \(binding.y)")
            }
        }
    }

    /// Meters: input (pre-fader) and output (post-on) for each strip type.
    /// Subscriptions lapse, so they're renewed.
    private func startMeters() {
        meterRenewal.start(every: 8, immediately: true) { [weak self] in
            guard let self else { return }
            for kind in self.kinds {
                if kind.isInput { self.line("mtrstart MIXER:Current/Meter/\(kind.path)/PreFader 100") }
                self.line("mtrstart MIXER:Current/Meter/\(kind.path)/PostOn 100")
            }
        }
    }

    private func receive(_ data: Data) {
        var meters: [String: MeterReading] = [:]
        for text in lines.feed(data) {
            let words = splitWords(text)
            guard words.count >= 2, ["OK", "OKM", "NOTIFY"].contains(words[0].uppercased()) else { continue }
            lastHeard = .now
            if !answered {
                answered = true
                sink.state(.connected)
                readEverything()
            }
            if words[1] == "prminfo" {
                if let info = ParameterInfo(words: words) { discovered[info.path] = info }
                continue
            }
            if words[1] == "mtr", words.count >= 4 {
                readMeters(words, into: &meters)
                continue
            }
            guard ["get", "set"].contains(words[1]), words.count >= 6, let x = Int(words[3]), let y = Int(words[4]) else { continue }
            let path = words[2]
            let value = words[5]
            if let suffix = suffixByPathAndY["\(path) \(y)"], let raw = Int(value) {
                let kindPath = Self.kindPath(of: path)
                guard let stripID = stripByAddress["\(kindPath) \(x)"] else { continue }
                let id = ControlID("\(stripID).\(suffix)")
                guard let binding = bindings[id] else { continue }
                sink.value(id, binding.info.isSwitch ? .on(raw != 0) : .level(binding.info.position(raw: raw)))
                continue
            }
            guard path.hasPrefix("MIXER:Current/") else { continue }
            let rest = path.dropFirst("MIXER:Current/".count).split(separator: "/", maxSplits: 1)
            guard rest.count == 2, let id = stripByAddress["\(rest[0]) \(x)"] else { continue }
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
        if !meters.isEmpty { sink.meters(meters) }
    }

    /// "IO:Current/InCh/HAGain" or "MIXER:Current/InCh/PEQ/Band/Freq" -> "InCh"
    static func kindPath(of path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// `NOTIFY mtr MIXER:Current/Meter/InCh/PreFader <type> 1a 2b …`: one hex value
    /// (0–127, 127 at the top) per channel.
    private func readMeters(_ words: [String], into meters: inout [String: MeterReading]) {
        let parts = words[2].split(separator: "/")
        guard parts.count >= 4, parts[1] == "Meter" else { return }
        let kindPath = String(parts[2])
        let isInput = parts[3] == "PreFader"
        for (x, word) in words.dropFirst(4).enumerated() {
            guard let raw = Int(word, radix: 16), let id = stripByAddress["\(kindPath) \(x)"] else { continue }
            var reading = meters[id] ?? MeterReading()
            if isInput { reading.input = Double(raw) / 127 } else { reading.output = Double(raw) / 127 }
            meters[id] = reading
        }
    }
}
