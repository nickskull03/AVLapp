import XCTest
@testable import ShowKit

final class OSCTests: XCTestCase {
    func testEncodesAddressTagsAndBigEndianInt() {
        let data = OSCMessage("/ab", [.int(1)]).encoded()
        XCTAssertEqual([UInt8](data), [
            0x2F, 0x61, 0x62, 0x00, // "/ab" + null, padded to 4
            0x2C, 0x69, 0x00, 0x00, // ",i"
            0x00, 0x00, 0x00, 0x01
        ])
    }

    func testPadsAStringWhoseLengthIsAMultipleOfFour() {
        let data = OSCMessage("/abc").encoded()
        XCTAssertEqual(data.count, 8 + 4) // "/abc" needs a whole extra word for its null
        XCTAssertEqual([UInt8](data.prefix(8)), [0x2F, 0x61, 0x62, 0x63, 0, 0, 0, 0])
    }

    func testRoundTripsEveryArgumentType() {
        let message = OSCMessage("/ch/01/mix/fader", [
            .float(0.75), .int(-3), .string("Lead Vox"), .blob(Data([1, 2, 3])), .bool(true), .bool(false)
        ])
        XCTAssertEqual(OSCMessage.decode(message.encoded()), [message])
    }

    func testDecodesBundles() {
        var bundle = Data("#bundle".utf8)
        bundle.append(0)
        bundle.append(contentsOf: [UInt8](repeating: 0, count: 8)) // time tag
        for message in [OSCMessage("/a", [.int(1)]), OSCMessage("/b", [.float(0.5)])] {
            let encoded = message.encoded()
            bundle.appendBigEndian(UInt32(encoded.count))
            bundle.append(encoded)
        }
        XCTAssertEqual(OSCMessage.decode(bundle), [OSCMessage("/a", [.int(1)]), OSCMessage("/b", [.float(0.5)])])
    }

    func testAcceptsAMessageWithoutTypeTags() {
        XCTAssertEqual(OSCMessage.decode(Data("/xinfo\0\0".utf8)), [OSCMessage("/xinfo")])
    }

    func testIgnoresGarbage() {
        XCTAssertEqual(OSCMessage.decode(Data([0x41, 0x42])), [])
        XCTAssertEqual(OSCMessage.decode(Data("/a\0\0,i\0\0\0\0".utf8)), []) // int cut short
    }

    func testLengthFramerReassemblesPacketsSplitAcrossReads() {
        let a = OSCMessage("/eos/out/fader/1/1", [.float(0.5)]).encoded()
        let b = OSCMessage("/eos/out/ping").encoded()
        let stream = OSCLengthFramer.frame(a) + OSCLengthFramer.frame(b)
        var framer = OSCLengthFramer()
        XCTAssertEqual(framer.feed(stream.prefix(7)), [])
        XCTAssertEqual(framer.feed(stream.dropFirst(7)), [a, b])
    }
}

final class AudioTaperTests: XCTestCase {
    func testMatchesTheX32LawAtItsBreakpoints() {
        XCTAssertNil(AudioTaper.decibels(position: 0))
        XCTAssertEqual(AudioTaper.decibels(position: 0.0625)!, -60, accuracy: 1e-9)
        XCTAssertEqual(AudioTaper.decibels(position: 0.25)!, -30, accuracy: 1e-9)
        XCTAssertEqual(AudioTaper.decibels(position: 0.5)!, -10, accuracy: 1e-9)
        XCTAssertEqual(AudioTaper.decibels(position: 0.75)!, 0, accuracy: 1e-9)
        XCTAssertEqual(AudioTaper.decibels(position: 1)!, 10, accuracy: 1e-9)
        XCTAssertEqual(AudioTaper.unity, 0.75, accuracy: 1e-9)
    }

    func testRoundTripsWithoutDrift() {
        for i in 1...1000 {
            let position = Double(i) / 1000
            XCTAssertEqual(AudioTaper.position(decibels: AudioTaper.decibels(position: position)), position, accuracy: 1e-9)
        }
        XCTAssertEqual(AudioTaper.position(decibels: nil), 0)
        XCTAssertEqual(AudioTaper.position(decibels: 20), 1)
    }

    func testFormatsForDisplay() {
        XCTAssertEqual(AudioTaper.text(position: 0), "−∞")
        XCTAssertEqual(AudioTaper.text(position: 0.75), "0.0")
        XCTAssertEqual(AudioTaper.text(position: 1), "+10.0")
        XCTAssertEqual(AudioTaper.text(position: 0.5), "-10")
        XCTAssertEqual(AudioTaper.text(position: 0.7), "-2.0")
    }
}

final class MIDIParserTests: XCTestCase {
    func testFollowsRunningStatus() {
        var parser = MIDIParser()
        // Note on, then a second note on with the status byte left out.
        XCTAssertEqual(parser.feed([0x90, 0x05, 0x7F, 0x05, 0x00]), [
            .noteOn(channel: 0, note: 5, velocity: 0x7F),
            .noteOn(channel: 0, note: 5, velocity: 0)
        ])
    }

    func testReportsNRPNWithAndWithoutFineValue() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.feed([0xB2, 0x63, 0x10, 0x62, 0x17, 0x06, 0x6B]), [
            .nrpn(channel: 2, parameter: 0x10 << 7 | 0x17, coarse: 0x6B, fine: nil)
        ])
        XCTAssertEqual(parser.feed([0xB2, 0x26, 0x05]), [
            .nrpn(channel: 2, parameter: 0x10 << 7 | 0x17, coarse: 0x6B, fine: 0x05)
        ])
    }

    func testCollectsSysexAcrossReadsAndSkipsRealTimeBytes() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.feed([0xF0, 0x00, 0xF8, 0x01]), [])
        XCTAssertEqual(parser.feed([0x02, 0xF7, 0xC0, 0x05]), [.sysex([0xF0, 0x00, 0x01, 0x02, 0xF7]), .programChange(channel: 0, program: 5)])
    }

    func testBuildsNRPN() {
        XCTAssertEqual(NRPN.set(channel: 0, parameter: 0x40 << 7 | 0x05, coarse: 0x76, fine: 0x20),
                       [0xB0, 0x63, 0x40, 0xB0, 0x62, 0x05, 0xB0, 0x06, 0x76, 0xB0, 0x26, 0x20])
    }
}

final class LineTests: XCTestCase {
    func testSplitsLinesAcrossReads() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Data("OK set A 0 0 1\r\nNOT".utf8)), ["OK set A 0 0 1"])
        XCTAssertEqual(splitter.feed(Data("IFY x\n".utf8)), ["NOTIFY x"])
    }

    func testKeepsQuotedWordsWhole() {
        XCTAssertEqual(splitWords(#"OK get MIXER:Current/InCh/Label/Name 0 0 "Lead Vox""#),
                       ["OK", "get", "MIXER:Current/InCh/Label/Name", "0", "0", "Lead Vox"])
        XCTAssertEqual(splitWords(#"OK get X 0 0 """#).last, "")
    }
}

final class ArtNetTests: XCTestCase {
    func testBuildsAnArtDmxPacket() {
        let packet = [UInt8](ArtNet.dmxPacket(universe: 0x0123, sequence: 7, slots: [255, 128, 0]))
        XCTAssertEqual(Array(packet.prefix(8)), Array("Art-Net\0".utf8))
        XCTAssertEqual(Array(packet[8..<18]), [0x00, 0x50, 0x00, 14, 7, 0, 0x23, 0x01, 0x00, 0x04])
        XCTAssertEqual(Array(packet[18...]), [255, 128, 0, 0]) // padded to an even length
    }
}
