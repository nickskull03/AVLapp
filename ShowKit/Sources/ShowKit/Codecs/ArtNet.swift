import Foundation

/// Art-Net's ArtDmx packet: one universe of DMX over UDP port 6454.
public enum ArtNet {
    public static let port: UInt16 = 6454

    /// `universe` is the 15-bit port-address (net << 8 | sub-net << 4 | universe).
    /// `sequence` 1–255 lets receivers reorder; 0 turns that off.
    public static func dmxPacket(universe: Int, sequence: UInt8, slots: [UInt8]) -> Data {
        var data = Data("Art-Net".utf8)
        data.append(0)
        data.append(contentsOf: [0x00, 0x50]) // OpDmx, little-endian
        data.append(contentsOf: [0x00, 14]) // protocol version 14, big-endian
        data.append(sequence)
        data.append(0) // physical input port: informational
        let address = max(0, min(0x7FFF, universe))
        data.append(UInt8(address & 0xFF)) // SubUni
        data.append(UInt8(address >> 8)) // Net
        var dmx = Array(slots.prefix(512))
        if dmx.isEmpty { dmx = [0, 0] }
        if dmx.count % 2 == 1 { dmx.append(0) } // length must be even
        data.append(UInt8(dmx.count >> 8))
        data.append(UInt8(dmx.count & 0xFF))
        data.append(contentsOf: dmx)
        return data
    }
}
