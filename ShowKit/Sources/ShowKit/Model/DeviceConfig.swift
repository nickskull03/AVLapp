import Foundation

/// Everything needed to reach and lay out one console. Saved with the show;
/// console *values* never are, because the desk is the source of truth.
public struct DeviceConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: DeviceKind
    public var name: String
    public var host: String
    public var port: Int
    public var variant: String
    /// A&H base MIDI channel, 1–16 (dLive 1–12).
    public var midiChannel: Int
    /// grandMA3 OSC prefix.
    public var oscPrefix: String
    /// Where the console sends feedback, for OSC-over-UDP lighting consoles.
    public var feedbackPort: Int
    /// grandMA3 page.
    public var page: Int
    /// First playback/fader shown; for grandMA3, the first column (x01–x90).
    public var firstNumber: Int
    public var count: Int
    /// grandMA3 "Fader Range": the value that means full.
    public var faderRange: Double
    /// Eos OSC user.
    public var user: Int
    /// Art-Net universe, 0–32767 (net, sub-net and universe combined).
    public var universe: Int
    public var autoConnect: Bool
    /// grandMA3: which executor rows each column shows (1 = 1xx under the
    /// fader, 2 = 2xx fader, 3 and 4 = the knob rows above).
    public var executorRows: [Int]
    /// grandMA3: follow the page the desk is on (needs the Show Deck plugin).
    public var followDeskPage: Bool
    /// Names, colours and button actions the user gave strips, by strip ID.
    public var customizations: [String: StripCustomization]

    public init(kind: DeviceKind, name: String? = nil, host: String = "") {
        id = UUID()
        self.kind = kind
        self.name = name ?? kind.shortTitle
        self.host = host
        port = kind.defaultPort
        variant = kind.variants.first?.id ?? ""
        midiChannel = 1
        oscPrefix = "gma3"
        // grandMA3 sends on the same port its OSC line receives on; MagicQ has its own TX port.
        feedbackPort = kind == .chamsysMagicQ ? 9000 : 8000
        page = 1
        switch kind {
        case .grandMA3: firstNumber = 1; count = 15
        case .chamsysMagicQ: firstNumber = 1; count = 10
        case .etcEos: firstNumber = 1; count = 10
        case .artNet: firstNumber = 1; count = 24
        default: firstNumber = 1; count = 0
        }
        faderRange = 100
        user = 2
        universe = 0
        autoConnect = true
        executorRows = [1, 2]
        followDeskPage = true
        customizations = [:]
    }

    // Decode field by field so shows saved by older versions still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(DeviceKind.self, forKey: .kind)
        self.init(kind: kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? variant
        midiChannel = try c.decodeIfPresent(Int.self, forKey: .midiChannel) ?? midiChannel
        oscPrefix = try c.decodeIfPresent(String.self, forKey: .oscPrefix) ?? oscPrefix
        feedbackPort = try c.decodeIfPresent(Int.self, forKey: .feedbackPort) ?? feedbackPort
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? page
        firstNumber = try c.decodeIfPresent(Int.self, forKey: .firstNumber) ?? firstNumber
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? count
        faderRange = try c.decodeIfPresent(Double.self, forKey: .faderRange) ?? faderRange
        user = try c.decodeIfPresent(Int.self, forKey: .user) ?? user
        universe = try c.decodeIfPresent(Int.self, forKey: .universe) ?? universe
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
        executorRows = try c.decodeIfPresent([Int].self, forKey: .executorRows) ?? executorRows
        followDeskPage = try c.decodeIfPresent(Bool.self, forKey: .followDeskPage) ?? followDeskPage
        customizations = try c.decodeIfPresent([String: StripCustomization].self, forKey: .customizations) ?? customizations
        // Older versions counted grandMA3 strips from executor 201; now they're columns.
        if kind == .grandMA3 && firstNumber > 100 { firstNumber %= 100 }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port, variant, midiChannel, oscPrefix, feedbackPort
        case page, firstNumber, count, faderRange, user, universe, autoConnect
        case executorRows, followDeskPage, customizations
    }

    /// Everything except customizations: when only those change, the
    /// connection doesn't need to be rebuilt.
    func sameConnection(as other: DeviceConfig) -> Bool {
        var a = self, b = other
        a.customizations = [:]
        b.customizations = [:]
        return a == b
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var port16: UInt16 { UInt16(clamping: port) }
    var feedbackPort16: UInt16 { UInt16(clamping: feedbackPort) }
}
