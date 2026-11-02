import Foundation

/// One OSC argument.
public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case bool(Bool)

    public var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        case .string, .blob: return nil
        }
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// An OSC 1.0 message: a padded address, padded type tags, then big-endian
/// arguments, all aligned to 4 bytes.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendOSCString(address)
        var tags = ","
        for argument in arguments {
            switch argument {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .blob: tags += "b"
            case .bool(let v): tags += v ? "T" : "F"
            }
        }
        data.appendOSCString(tags)
        for argument in arguments {
            switch argument {
            case .int(let v): data.appendBigEndian(UInt32(bitPattern: v))
            case .float(let v): data.appendBigEndian(v.bitPattern)
            case .string(let v): data.appendOSCString(v)
            case .blob(let v):
                data.appendBigEndian(UInt32(v.count))
                data.append(v)
                data.append(contentsOf: [UInt8](repeating: 0, count: (4 - v.count % 4) % 4))
            case .bool: break
            }
        }
        return data
    }

    /// Decodes one packet, flattening bundles. Malformed input gives [].
    public static func decode(_ data: Data) -> [OSCMessage] {
        var reader = OSCReader(bytes: [UInt8](data))
        return reader.readPacket(end: data.count)
    }
}

private struct OSCReader {
    let bytes: [UInt8]
    var position = 0

    mutating func readPacket(end: Int) -> [OSCMessage] {
        guard end <= bytes.count, position < end, let address = readString(end: end) else { return [] }
        if address == "#bundle" {
            guard position + 8 <= end else { return [] }
            position += 8 // time tag: we act on everything immediately
            var messages: [OSCMessage] = []
            while position + 4 <= end {
                guard let size = readUInt32(end: end).map(Int.init), size > 0, position + size <= end else { break }
                let next = position + size
                messages += readPacket(end: next)
                position = next
            }
            return messages
        }
        guard address.hasPrefix("/") else { return [] }
        // Some senders omit the type tag string when there are no arguments.
        guard position < end, let tags = readString(end: end), tags.hasPrefix(",") else {
            return [OSCMessage(address)]
        }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let v = readUInt32(end: end) else { return [] }
                arguments.append(.int(Int32(bitPattern: v)))
            case "f":
                guard let v = readUInt32(end: end) else { return [] }
                arguments.append(.float(Float(bitPattern: v)))
            case "d":
                guard let hi = readUInt32(end: end), let lo = readUInt32(end: end) else { return [] }
                arguments.append(.float(Float(Double(bitPattern: UInt64(hi) << 32 | UInt64(lo)))))
            case "h":
                guard let hi = readUInt32(end: end), let lo = readUInt32(end: end) else { return [] }
                arguments.append(.int(Int32(clamping: Int64(bitPattern: UInt64(hi) << 32 | UInt64(lo)))))
            case "s", "S":
                guard let v = readString(end: end) else { return [] }
                arguments.append(.string(v))
            case "b":
                guard let size = readUInt32(end: end).map(Int.init), position + size <= end else { return [] }
                arguments.append(.blob(Data(bytes[position..<position + size])))
                position += (size + 3) & ~3
            case "T": arguments.append(.bool(true))
            case "F": arguments.append(.bool(false))
            case "N", "I": break
            default: return [OSCMessage(address, arguments)] // unknown type: keep what we have
            }
        }
        return [OSCMessage(address, arguments)]
    }

    mutating func readUInt32(end: Int) -> UInt32? {
        guard position + 4 <= end else { return nil }
        let v = bytes[position..<position + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        position += 4
        return v
    }

    mutating func readString(end: Int) -> String? {
        guard position < end, let zero = bytes[position..<end].firstIndex(of: 0) else { return nil }
        let string = String(decoding: bytes[position..<zero], as: UTF8.self)
        position = min(end, position + ((zero - position) / 4 + 1) * 4) // past the terminator, padded to 4
        return string
    }
}

/// OSC over TCP, OSC 1.0 style: each packet is preceded by its length as a
/// big-endian 32-bit integer. Feed it the stream; it hands back whole packets.
public struct OSCLengthFramer: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public static func frame(_ packet: Data) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(packet.count))
        data.append(packet)
        return data
    }

    public mutating func feed(_ data: Data) -> [Data] {
        buffer += data
        var packets: [Data] = []
        while buffer.count >= 4 {
            let size = Int(buffer[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard size <= 1 << 20 else { buffer.removeAll(); break } // garbage: resync
            guard buffer.count >= 4 + size else { break }
            packets.append(Data(buffer[4..<4 + size]))
            buffer.removeFirst(4 + size)
        }
        return packets
    }
}

extension Data {
    mutating func appendOSCString(_ string: String) {
        let utf8 = Array(string.utf8)
        append(contentsOf: utf8)
        append(contentsOf: [UInt8](repeating: 0, count: 4 - utf8.count % 4))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
