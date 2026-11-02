import Foundation

/// Allen & Heath dLive (and Avantis) over MIDI on TCP: MixRack 51325,
/// Surface 51328 (unencrypted).
///
/// Strip types live on the base MIDI channel N and the four after it, each at
/// its own range of channel numbers (CH). Fader: NRPN with CC 0x63 = CH,
/// CC 0x62 = 0x17, CC 0x06 = level, where dB = level × 64/127 − 54 and 0 is −∞.
/// Mute: note CH with velocity 0x7F (on) or 0x3F (off), then velocity 0.
/// SysEx "get" requests read levels, mutes and names.
@MainActor
final class AllenHeathDLiveDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls = [ControlDescriptor("scene", "Recall scene", .number(1...500), needsConfirmation: true)]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    static let sysexHeader: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00]

    struct Bank {
        let id: String
        let title: String
        let short: String
        let offset: UInt8 // added to the base MIDI channel
        let first: UInt8 // CH of strip 1
        let count: Int
        let style: StripStyle
        var hasFader = true
    }

    static let banks: [Bank] = [
        Bank(id: "ip", title: "Inputs", short: "Ip", offset: 0, first: 0x00, count: 128, style: .input),
        Bank(id: "grp", title: "Mono Groups", short: "Grp", offset: 1, first: 0x00, count: 62, style: .bus),
        Bank(id: "stgrp", title: "Stereo Groups", short: "StGrp", offset: 1, first: 0x40, count: 31, style: .bus),
        Bank(id: "aux", title: "Mono Auxes", short: "Aux", offset: 2, first: 0x00, count: 62, style: .bus),
        Bank(id: "staux", title: "Stereo Auxes", short: "StAux", offset: 2, first: 0x40, count: 31, style: .bus),
        Bank(id: "mtx", title: "Mono Matrices", short: "Mtx", offset: 3, first: 0x00, count: 62, style: .bus),
        Bank(id: "stmtx", title: "Stereo Matrices", short: "StMtx", offset: 3, first: 0x40, count: 31, style: .bus),
        Bank(id: "fxs", title: "Mono FX Sends", short: "FX", offset: 4, first: 0x00, count: 16, style: .fx),
        Bank(id: "stfxs", title: "Stereo FX Sends", short: "StFX", offset: 4, first: 0x10, count: 16, style: .fx),
        Bank(id: "fxr", title: "FX Returns", short: "FXR", offset: 4, first: 0x20, count: 16, style: .fx),
        Bank(id: "main", title: "Mains", short: "Main", offset: 4, first: 0x30, count: 6, style: .master),
        Bank(id: "dca", title: "DCAs", short: "DCA", offset: 4, first: 0x36, count: 24, style: .dca),
        Bank(id: "mg", title: "Mute Groups", short: "MG", offset: 4, first: 0x4E, count: 8, style: .muteGroup, hasFader: false),
        Bank(id: "ufxs", title: "UFX Sends", short: "UFX", offset: 4, first: 0x56, count: 8, style: .fx),
        Bank(id: "ufxr", title: "UFX Returns", short: "UFXR", offset: 4, first: 0x5E, count: 8, style: .fx)
    ]

    /// Where a strip lives on the wire.
    struct Address: Hashable {
        let offset: UInt8
        let ch: UInt8
    }

    static func wireLevel(decibels: Double?) -> UInt8 {
        guard let db = decibels, db > -54 else { return 0 }
        return UInt8(max(1, min(127, ((db + 54) / 64 * 127).rounded())))
    }

    static func decibels(level: UInt8) -> Double? {
        level == 0 ? nil : Double(level) * 64 / 127 - 54
    }

    private let n: UInt8
    private let transport: Transport
    private var parser = MIDIParser()
    private let pacer = QueryPacer(perTick: 12, interval: 0.03)
    private var addresses: [String: Address] = [:] // strip id -> address
    private var stripsByAddress: [Address: String] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        n = UInt8(max(1, min(12, config.midiChannel)) - 1)
        transport = makeTransport(.tcp(host: config.trimmedHost, port: config.port16))

        var addresses: [String: Address] = [:]
        groups = Self.banks.map { bank in
            StripGroup(id: bank.id, title: bank.title, strips: (0..<bank.count).map { i in
                let id = "\(bank.id).\(i + 1)"
                addresses[id] = Address(offset: bank.offset, ch: bank.first + UInt8(i))
                return Strip(
                    id: id, name: "\(bank.short) \(i + 1)", style: bank.style,
                    fader: bank.hasFader ? ControlDescriptor(ControlID("\(id).level"), "Fader", .fader(.decibels)) : nil,
                    buttons: [ControlDescriptor(ControlID("\(id).mute"), "Mute", .toggle(.mute), needsConfirmation: bank.id == "main")]
                )
            })
        }
        self.addresses = addresses
        stripsByAddress = Dictionary(uniqueKeysWithValues: addresses.map { ($0.value, $0.key) })

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
            let s = max(0, min(499, scene - 1))
            transport.send(Data([0xB0 | n, 0x00, UInt8(s / 128), 0xC0 | n, UInt8(s % 128)]))
            return
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, let address = addresses["\(parts[0]).\(parts[1])"] else { return }
        let midiChannel = n + address.offset
        switch (parts[2], value) {
        case ("level", .level(let position)):
            let level = Self.wireLevel(decibels: AudioTaper.decibels(position: position))
            transport.send(Data([0xB0 | midiChannel, 0x63, address.ch, 0xB0 | midiChannel, 0x62, 0x17, 0xB0 | midiChannel, 0x06, level]))
        case ("mute", .on(let muted)):
            let note = 0x90 | midiChannel
            transport.send(Data([note, address.ch, muted ? 0x7F : 0x3F, note, address.ch, 0x00]))
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
        var queries: [Data] = []
        for bank in Self.banks {
            for i in 0..<bank.count {
                let channelByte = n + bank.offset
                let ch = bank.first + UInt8(i)
                if bank.hasFader { queries.append(Data(Self.sysexHeader + [channelByte, 0x05, 0x0B, 0x17, ch, 0xF7])) }
                queries.append(Data(Self.sysexHeader + [channelByte, 0x05, 0x09, ch, 0xF7]))
                queries.append(Data(Self.sysexHeader + [channelByte, 0x01, ch, 0xF7]))
            }
        }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.sink.synced()
            }
        }
    }

    private func strip(midiChannel: UInt8, ch: UInt8) -> String? {
        guard midiChannel >= n, midiChannel - n <= 4 else { return nil }
        return stripsByAddress[Address(offset: midiChannel - n, ch: ch)]
    }

    private func receive(_ data: Data) {
        for message in parser.feed(data) {
            switch message {
            case let .noteOn(channel, note, velocity):
                // Velocity 0 is the note-off that follows each mute message.
                guard velocity != 0, let id = strip(midiChannel: channel, ch: note) else { continue }
                sink.value(ControlID("\(id).mute"), .on(velocity >= 0x40))
            case let .nrpn(channel, parameter, coarse, _):
                guard parameter & 0x7F == 0x17, let id = strip(midiChannel: channel, ch: UInt8(parameter >> 7)) else { continue }
                sink.value(ControlID("\(id).level"), .level(AudioTaper.position(decibels: Self.decibels(level: coarse))))
            case let .sysex(bytes):
                // Name reply: header, 0N, 02, CH, name…, F7
                let h = Self.sysexHeader.count
                guard bytes.count >= h + 4, Array(bytes.prefix(h)) == Self.sysexHeader, bytes[h + 1] == 0x02,
                      let id = strip(midiChannel: bytes[h], ch: bytes[h + 2]) else { continue }
                let name = String(decoding: bytes[(h + 3)..<(bytes.count - 1)].filter { $0 != 0 }, as: UTF8.self)
                sink.name(id, name.trimmingCharacters(in: .whitespaces))
            default:
                continue
            }
        }
    }
}
