import Foundation

/// A MIDI message as the stream parser reports it. Channels are 0–15.
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case pitchBend(channel: UInt8, value: UInt16)
    case sysex([UInt8]) // including F0 and F7
    /// An NRPN data entry: CC 0x63/0x62 chose `parameter` (14-bit), then CC 0x06
    /// set `coarse`. `fine` is set when CC 0x26 follows.
    case nrpn(channel: UInt8, parameter: UInt16, coarse: UInt8, fine: UInt8?)
}

/// Turns a MIDI byte stream into messages. Handles running status (a sender
/// may leave out a repeated status byte), interleaved real-time bytes, SysEx,
/// and NRPN sequences, whose parameter number sticks per channel until changed.
public struct MIDIParser: Sendable {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]? = nil
    private var nrpnParameter: [UInt8: UInt16] = [:]
    private var nrpnCoarse: [UInt8: UInt8] = [:]

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [MIDIMessage] where S.Element == UInt8 {
        var out: [MIDIMessage] = []
        for byte in bytes {
            if byte >= 0xF8 { continue } // real-time: may appear anywhere
            if byte == 0xF0 {
                sysex = [byte]
                continue
            }
            if var buffer = sysex {
                if byte == 0xF7 {
                    buffer.append(byte)
                    out.append(.sysex(buffer))
                    sysex = nil
                } else if byte & 0x80 != 0 {
                    sysex = nil // unterminated: drop it, treat this as a new status
                    startStatus(byte)
                } else {
                    buffer.append(byte)
                    sysex = buffer
                }
                continue
            }
            if byte & 0x80 != 0 {
                startStatus(byte)
                continue
            }
            guard status != 0 else { continue }
            data.append(byte)
            let kind = status & 0xF0
            guard data.count == ((kind == 0xC0 || kind == 0xD0) ? 1 : 2) else { continue }
            out += handle(status: status, data: data)
            data.removeAll(keepingCapacity: true)
        }
        return out
    }

    private mutating func startStatus(_ byte: UInt8) {
        status = byte < 0xF0 ? byte : 0 // system common messages cancel running status
        data.removeAll(keepingCapacity: true)
    }

    private mutating func handle(status: UInt8, data: [UInt8]) -> [MIDIMessage] {
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x80:
            return [.noteOff(channel: channel, note: data[0], velocity: data[1])]
        case 0x90:
            return [.noteOn(channel: channel, note: data[0], velocity: data[1])]
        case 0xB0:
            let value = data[1]
            switch data[0] {
            case 0x63:
                nrpnParameter[channel] = UInt16(value) << 7 | ((nrpnParameter[channel] ?? 0) & 0x7F)
                nrpnCoarse[channel] = nil
                return []
            case 0x62:
                nrpnParameter[channel] = ((nrpnParameter[channel] ?? 0) & 0x3F80) | UInt16(value)
                nrpnCoarse[channel] = nil
                return []
            case 0x06:
                guard let parameter = nrpnParameter[channel] else { break }
                nrpnCoarse[channel] = value
                return [.nrpn(channel: channel, parameter: parameter, coarse: value, fine: nil)]
            case 0x26:
                guard let parameter = nrpnParameter[channel], let coarse = nrpnCoarse[channel] else { break }
                return [.nrpn(channel: channel, parameter: parameter, coarse: coarse, fine: value)]
            default:
                break
            }
            return [.controlChange(channel: channel, controller: data[0], value: value)]
        case 0xC0:
            return [.programChange(channel: channel, program: data[0])]
        case 0xE0:
            return [.pitchBend(channel: channel, value: UInt16(data[1]) << 7 | UInt16(data[0]))]
        default:
            return []
        }
    }
}

/// Builders for the NRPN messages A&H mixers use.
public enum NRPN {
    /// CC 0x63 (parameter MSB), 0x62 (LSB), 0x06 (value), and 0x26 (fine) when given.
    public static func set(channel: UInt8, parameter: UInt16, coarse: UInt8, fine: UInt8? = nil) -> [UInt8] {
        let b = 0xB0 | (channel & 0x0F)
        var bytes = [b, 0x63, UInt8(parameter >> 7 & 0x7F), b, 0x62, UInt8(parameter & 0x7F), b, 0x06, coarse & 0x7F]
        if let fine { bytes += [b, 0x26, fine & 0x7F] }
        return bytes
    }
}
