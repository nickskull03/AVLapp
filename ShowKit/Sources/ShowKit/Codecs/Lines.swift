import Foundation

/// Splits a text stream into lines at "\n" (dropping any "\r").
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                lines.append(String(decoding: buffer.filter { $0 != 0x0D }, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        if buffer.count > 65536 { buffer.removeAll() } // no newline in sight: give up on it
        return lines
    }
}

/// Splits a line into words at spaces, keeping "quoted strings" whole (without the quotes).
public func splitWords(_ line: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quoted = false
    var inWord = false
    for ch in line {
        if ch == "\"" {
            quoted.toggle()
            inWord = true
        } else if ch == " " && !quoted {
            if inWord { words.append(current) }
            current = ""
            inWord = false
        } else {
            current.append(ch)
            inWord = true
        }
    }
    if inWord { words.append(current) }
    return words
}
