import Foundation

/// Allen & Heath SQ-5/6/7 over MIDI on TCP 51325.
///
/// Everything is an NRPN: parameter MSB/LSB, then a value as VC (CC 0x06) and
/// VF (CC 0x26). Levels use the mixer's "Linear Taper" NRPN fader law, a
/// 14-bit value where dB ≈ (value − 15196) / 118.775. Mutes are VF 1 or 0.
/// A "get" is the parameter followed by CC 0x60 with 0x7F; the mixer answers
/// with the value. Tables are from the SQ MIDI protocol, as used by the
/// Bitfocus Companion SQ module.
@MainActor
final class AllenHeathSQDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls = [ControlDescriptor("scene", "Recall scene", .number(1...300), needsConfirmation: true)]
    let traits = DriverTraits(reportsChanges: true, readsNames: false)

    private enum Kind { case level, mute }

    private let channel: UInt8
    private let transport: Transport
    private var parser = MIDIParser()
    private let pacer = QueryPacer()
    private var params: [ControlID: (UInt16, Kind)] = [:]
    private var controls: [UInt16: (ControlID, Kind)] = [:]

    static func nrpn(_ msb: UInt16, _ lsb: UInt16, plus offset: Int = 0) -> UInt16 {
        (msb << 7 | lsb) + UInt16(offset)
    }

    /// dB (nil = −∞) to VC/VF under Linear Taper.
    static func wireLevel(decibels: Double?) -> (UInt8, UInt8) {
        guard let db = decibels, db > -89 else { return (0, 0) }
        let value = Int((15196 + min(10, db) * 118.775).rounded(.down))
        return (UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F))
    }

    static func decibels(vc: UInt8, vf: UInt8) -> Double? {
        let db = (Double(Int(vc) << 7 | Int(vf)) - 15196) / 118.775
        return db < -89 ? nil : min(10, db)
    }

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        channel = UInt8(max(1, min(16, config.midiChannel)) - 1)
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))

        var params: [ControlID: (UInt16, Kind)] = [:]

        func strips(_ id: String, _ name: String, _ count: Int, _ style: StripStyle,
                    level: (UInt16, UInt16)?, mute: (UInt16, UInt16), confirmMute: Bool = false) -> [Strip] {
            (0..<count).map { i in
                let stripID = count == 1 ? id : "\(id).\(i + 1)"
                let muteID = ControlID("\(stripID).mute")
                params[muteID] = (Self.nrpn(mute.0, mute.1, plus: i), .mute)
                var fader: ControlDescriptor? = nil
                if let level {
                    let levelID = ControlID("\(stripID).level")
                    params[levelID] = (Self.nrpn(level.0, level.1, plus: i), .level)
                    fader = ControlDescriptor(levelID, "Fader", .fader(.decibels))
                }
                return Strip(id: stripID, name: count == 1 ? name : "\(name) \(i + 1)", style: style, fader: fader,
                             buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute), needsConfirmation: confirmMute)])
            }
        }

        groups = [
            // Input faders here are their level into LR.
            StripGroup(id: "ip", title: "Inputs", strips: strips("ip", "Ip", 48, .input, level: (0x40, 0x00), mute: (0x00, 0x00))),
            StripGroup(id: "fxr", title: "FX Returns", strips: strips("fxr", "FX Rtn", 8, .fx, level: (0x40, 0x3C), mute: (0x00, 0x3C))),
            StripGroup(id: "grp", title: "Groups", strips: strips("grp", "Grp", 12, .bus, level: (0x40, 0x30), mute: (0x00, 0x30))),
            StripGroup(id: "mix", title: "Mixes", strips: strips("mix", "Mix", 12, .bus, level: (0x4F, 0x01), mute: (0x00, 0x45))),
            StripGroup(id: "fxs", title: "FX Sends", strips: strips("fxs", "FX Send", 4, .fx, level: (0x4F, 0x0D), mute: (0x00, 0x51))),
            StripGroup(id: "mtx", title: "Matrices", strips: strips("mtx", "Mtx", 3, .bus, level: (0x4F, 0x11), mute: (0x00, 0x55))),
            StripGroup(id: "dca", title: "DCAs", strips: strips("dca", "DCA", 8, .dca, level: (0x4F, 0x20), mute: (0x02, 0x00))),
            StripGroup(id: "lr", title: "Main", strips: strips("lr", "Main LR", 1, .master, level: (0x4F, 0x00), mute: (0x00, 0x44), confirmMute: true)),
            StripGroup(id: "mg", title: "Mute Groups", strips: strips("mg", "Mute Grp", 8, .muteGroup, level: nil, mute: (0x04, 0x00)))
        ]
        self.params = params
        controls = Dictionary(uniqueKeysWithValues: params.map { ($0.value.0, ($0.key, $0.value.1)) })

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        parser = MIDIParser()
        transport.open()
    }

    func stop() {
        pacer.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        if id == "scene", case .number(let scene) = value {
            let n = max(0, min(299, scene - 1))
            transport.send(Data([0xB0 | channel, 0x00, UInt8(n >> 7), 0xC0 | channel, UInt8(n & 0x7F)]))
            return
        }
        guard case let (param, kind)? = params[id] else { return }
        switch (kind, value) {
        case (.level, .level(let position)):
            let (vc, vf) = Self.wireLevel(decibels: AudioTaper.decibels(position: position))
            transport.send(Data(NRPN.set(channel: channel, parameter: param, coarse: vc, fine: vf)))
        case (.mute, .on(let muted)):
            transport.send(Data(NRPN.set(channel: channel, parameter: param, coarse: 0, fine: muted ? 1 : 0)))
        default:
            break
        }
    }

    // MARK: Private

    private func transportState(_ state: TransportState) {
        guard state == .ready else {
            pacer.stop()
            sink.state(state.linkState)
            return
        }
        sink.state(.connected)
        let b = 0xB0 | channel
        let queries = params.values.map { entry -> Data in
            let param = entry.0
            return Data([b, 0x63, UInt8(param >> 7 & 0x7F), b, 0x62, UInt8(param & 0x7F), b, 0x60, 0x7F])
        }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.sink.synced()
            }
        }
    }

    private func receive(_ data: Data) {
        for message in parser.feed(data) {
            guard case let .nrpn(ch, param, coarse, fine) = message, ch == channel,
                  let fine, case let (id, kind)? = controls[param] else { continue }
            switch kind {
            case .level: sink.value(id, .level(AudioTaper.position(decibels: Self.decibels(vc: coarse, vf: fine))))
            case .mute: sink.value(id, .on(fine & 0x01 == 1))
            }
        }
    }
}
