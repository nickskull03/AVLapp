import Foundation

/// The original Allen & Heath Qu (Qu-16, Qu-24, Qu-32, Qu-Pac, Qu-SB) over MIDI
/// on TCP 51325. Not the same protocol as the new Qu-5/6/7 (see
/// `AllenHeathSQDriver`): each strip is one MIDI "channel number" (CH below),
/// and its messages are short.
///
/// - Fader: NRPN with the strip as MSB and 0x17 as LSB, a 7-bit value on the
///   desk's own fader law, then 0x07 as the fine byte:
///   `BN 63 CH BN 62 17 BN 06 VA BN 26 07`.
/// - Mute: `9N CH 7F` (on) or `9N CH 3F` (off), then `8N CH 00`. The desk
///   reports mutes the same way: velocity 40–7F muted, 01–3F not.
/// - Names: SysEx `F0 00 00 1A 50 11 01 00 0N 01 CH F7`; the reply is
///   `… 02 CH <name> F7`.
/// - "Get system state" (`… 10 01 F7`) makes the desk send every value.
/// - Scenes 1–100: `BN 00 00 CN <scene − 1>`.
/// - The app sends Active Sensing (FE) every second, as the desk expects.
///
/// From the Qu MIDI Protocol (firmware 1.9), as used by the Bitfocus
/// Companion Qu module.
@MainActor
final class AllenHeathQuClassicDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls = [ControlDescriptor("scene", "Recall scene", .number(1...100), needsConfirmation: true)]
    let traits = DriverTraits(
        reportsChanges: true, readsNames: true,
        note: "The original Qu's MIDI protocol covers levels, mutes, names and scenes: no EQ, dynamics, gain or meters."
    )

    private let channel: UInt8
    private let transport: Transport
    private var parser = MIDIParser()
    private let keepAlive = Ticker()
    private let syncDelay = Ticker()
    /// Strip id by the desk's channel number, and back.
    private let stripByCH: [UInt8: String]
    private let chByStrip: [String: UInt8]

    static let faderParameter: UInt8 = 0x17

    /// (dB, value) on the desk's fader law, from the protocol's table, loudest first.
    static let taper: [(Double, Int)] = [
        (10, 0x7F), (9, 0x7C), (8, 0x7A), (7, 0x78), (6, 0x76), (5, 0x73), (4, 0x71), (3, 0x6D),
        (2, 0x69), (1, 0x65), (0, 0x62), (-1, 0x5F), (-2, 0x5B), (-3, 0x55), (-4, 0x52), (-5, 0x4F),
        (-6, 0x4C), (-7, 0x48), (-8, 0x44), (-9, 0x3F), (-10, 0x3E), (-11, 0x3C), (-12, 0x3A), (-13, 0x39),
        (-14, 0x38), (-15, 0x36), (-16, 0x35), (-17, 0x33), (-18, 0x31), (-19, 0x30), (-20, 0x2F), (-21, 0x2D),
        (-22, 0x2B), (-23, 0x29), (-24, 0x28), (-25, 0x27), (-26, 0x25), (-27, 0x23), (-28, 0x21), (-29, 0x20),
        (-30, 0x1F), (-31, 0x1D), (-32, 0x1B), (-33, 0x19), (-34, 0x18), (-35, 0x17), (-36, 0x15), (-37, 0x13),
        (-38, 0x11), (-39, 0x10), (-40, 0x0F), (-45, 0x0C), (-50, 0x08), (-55, 0x07)
    ]

    /// dB (nil = −∞) to the desk's 7-bit fader value.
    static func wireLevel(decibels: Double?) -> UInt8 {
        guard let db = decibels, db >= -57.5 else { return 0 }
        if db >= 10 { return 0x7F }
        if db <= -55 { return 0x07 }
        for i in 1..<taper.count where db >= taper[i].0 {
            let (db0, v0) = taper[i - 1], (db1, v1) = taper[i]
            let value = Double(v1) + (db - db1) / (db0 - db1) * Double(v0 - v1)
            return UInt8(value.rounded())
        }
        return 0x07
    }

    /// The desk's 7-bit fader value to dB (nil = −∞).
    static func decibels(value: UInt8) -> Double? {
        let v = Int(value)
        if v == 0 { return nil }
        if v < 0x07 { return -55 - Double(0x07 - v) * 5 } // below the table: down towards −85
        for i in 1..<taper.count where v >= taper[i].1 {
            let (db0, v0) = taper[i - 1], (db1, v1) = taper[i]
            guard v0 != v1 else { return db1 }
            return db1 + Double(v - v1) / Double(v0 - v1) * (db0 - db1)
        }
        return -55
    }

    /// The SysEx header for this desk's MIDI channel.
    private var sysexHeader: [UInt8] { [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, channel] }

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        channel = UInt8(max(1, min(16, config.midiChannel)) - 1)
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))

        let model = config.variant.isEmpty ? "qu32" : config.variant
        let inputs = model == "qu16" ? 16 : model == "qu24" ? 24 : 32
        let hasGroups = model != "qu16"

        var byCH: [UInt8: String] = [:]
        func strip(_ id: String, _ name: String, _ ch: UInt8, _ style: StripStyle,
                   fader: Bool = true, confirmMute: Bool = false) -> Strip {
            byCH[ch] = id
            return Strip(
                id: id, name: name, style: style,
                fader: fader ? ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.decibels)) : nil,
                buttons: [ControlDescriptor(ControlID("\(id).mute"), "Mute", .toggle(.mute), needsConfirmation: confirmMute)]
            )
        }
        func run(_ prefix: String, _ names: [String], from first: UInt8, _ style: StripStyle, fader: Bool = true) -> [Strip] {
            names.enumerated().map { i, name in strip("\(prefix).\(i + 1)", name, first + UInt8(i), style, fader: fader) }
        }

        // Mixes 1–4 are mono, 5/6 to 9/10 stereo; groups and matrices are stereo pairs.
        let mixNames = ["Mix 1", "Mix 2", "Mix 3", "Mix 4", "Mix 5/6", "Mix 7/8", "Mix 9/10"]
        var groups = [
            StripGroup(id: "ip", title: "Inputs", strips: run("ip", (1...inputs).map { "Ch \($0)" }, from: 0x20, .input)),
            StripGroup(id: "st", title: "Stereo", strips: run("st", ["ST1", "ST2", "ST3"], from: 0x40, .input)),
            StripGroup(id: "fxr", title: "FX Returns", strips: run("fxr", (1...4).map { "FX Rtn \($0)" }, from: 0x08, .fx)),
            StripGroup(id: "mix", title: "Mixes", strips: run("mix", mixNames, from: 0x60, .bus)),
            StripGroup(id: "fxs", title: "FX Sends", strips: run("fxs", (1...4).map { "FX Send \($0)" }, from: 0x00, .fx))
        ]
        if hasGroups {
            groups.append(StripGroup(id: "grp", title: "Groups", strips: run("grp", ["Grp 1/2", "Grp 3/4", "Grp 5/6", "Grp 7/8"], from: 0x68, .bus)))
            groups.append(StripGroup(id: "mtx", title: "Matrices", strips: run("mtx", ["Mtx 1/2", "Mtx 3/4"], from: 0x6C, .bus)))
        }
        groups += [
            StripGroup(id: "dca", title: "DCAs", strips: run("dca", (1...4).map { "DCA \($0)" }, from: 0x10, .dca)),
            StripGroup(id: "lr", title: "Main", strips: [strip("lr", "Main LR", 0x67, .master, confirmMute: true)]),
            StripGroup(id: "mg", title: "Mute Groups", strips: run("mg", (1...4).map { "Mute Grp \($0)" }, from: 0x50, .muteGroup, fader: false))
        ]
        self.groups = groups
        stripByCH = byCH
        chByStrip = Dictionary(uniqueKeysWithValues: byCH.map { ($0.value, $0.key) })

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        parser = MIDIParser()
        transport.open()
    }

    func stop() {
        keepAlive.stop()
        syncDelay.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        if id == "scene", case .number(let scene) = value {
            let n = UInt8(max(0, min(99, scene - 1)))
            transport.send(Data([0xB0 | channel, 0x00, 0x00, 0xC0 | channel, n]))
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard let last = parts.last, let ch = chByStrip[parts.dropLast().joined(separator: ".")] else { return }
        switch (last, value) {
        case ("level", .level(let position)):
            let va = Self.wireLevel(decibels: AudioTaper.decibels(position: position))
            transport.send(Data(NRPN.set(channel: channel, parameter: UInt16(ch) << 7 | UInt16(Self.faderParameter), coarse: va, fine: 0x07)))
        case ("mute", .on(let muted)):
            transport.send(Data([0x90 | channel, ch, muted ? 0x7F : 0x3F, 0x80 | channel, ch, 0x00]))
        default:
            break
        }
    }

    // MARK: Private

    private func transportState(_ state: TransportState) {
        guard state == .ready else {
            keepAlive.stop()
            syncDelay.stop()
            sink.state(state.linkState)
            return
        }
        sink.state(.connected)
        // Every value, then every name; the desk answers within a second or so.
        var request = Data(sysexHeader + [0x10, 0x01, 0xF7])
        for ch in stripByCH.keys.sorted() {
            request.append(contentsOf: sysexHeader + [0x01, ch, 0xF7])
        }
        transport.send(request)
        keepAlive.start(every: 1) { [weak self] in self?.transport.send(Data([0xFE])) }
        syncDelay.once(after: 1.5) { [weak self] in self?.sink.synced() }
    }

    private func receive(_ data: Data) {
        for message in parser.feed(data) {
            switch message {
            case let .noteOn(ch, note, velocity):
                guard ch == channel, velocity != 0, let id = stripByCH[note] else { continue }
                sink.value(ControlID("\(id).mute"), .on(velocity >= 0x40))
            case let .nrpn(ch, parameter, coarse, _):
                guard ch == channel, parameter & 0x7F == UInt16(Self.faderParameter),
                      let id = stripByCH[UInt8(parameter >> 7)] else { continue }
                sink.value(ControlID("\(id).level"), .level(AudioTaper.position(decibels: Self.decibels(value: coarse))))
            case let .sysex(bytes):
                let header = sysexHeader
                guard bytes.count > header.count + 2, Array(bytes.prefix(header.count)) == header,
                      bytes[header.count] == 0x02, let id = stripByCH[bytes[header.count + 1]] else { continue }
                let nameBytes = bytes[(header.count + 2)...].prefix { $0 != 0xF7 && $0 != 0x00 }
                sink.name(id, String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces))
            default:
                continue
            }
        }
    }
}
