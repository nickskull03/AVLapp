import Foundation

/// A console family the app has a driver for.
public enum DeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Sound
    case behringerX32
    case behringerXAir
    case allenHeathSQ
    case allenHeathDLive
    case yamahaRCP
    // Lights
    case grandMA3
    case chamsysMagicQ
    case etcEos
    case artNet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .behringerX32: return "Behringer X32 / Midas M32"
        case .behringerXAir: return "Behringer X Air / Midas MR"
        case .allenHeathSQ: return "Allen & Heath SQ"
        case .allenHeathDLive: return "Allen & Heath dLive / Avantis"
        case .yamahaRCP: return "Yamaha TF / DM3 / CL / QL / DM7"
        case .grandMA3: return "grandMA3"
        case .chamsysMagicQ: return "ChamSys MagicQ"
        case .etcEos: return "ETC Eos family"
        case .artNet: return "Lights direct (Art-Net DMX)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .behringerX32: return "X32"
        case .behringerXAir: return "X Air"
        case .allenHeathSQ: return "SQ"
        case .allenHeathDLive: return "dLive"
        case .yamahaRCP: return "Yamaha"
        case .grandMA3: return "MA3"
        case .chamsysMagicQ: return "MagicQ"
        case .etcEos: return "Eos"
        case .artNet: return "DMX"
        }
    }

    public var domain: Domain {
        switch self {
        case .behringerX32, .behringerXAir, .allenHeathSQ, .allenHeathDLive, .yamahaRCP: return .audio
        case .grandMA3, .chamsysMagicQ, .etcEos, .artNet: return .lighting
        }
    }

    public var defaultPort: Int {
        switch self {
        case .behringerX32: return 10023
        case .behringerXAir: return 10024
        case .allenHeathSQ: return 51325
        case .allenHeathDLive: return 51325 // MixRack; the Surface is 51328
        case .yamahaRCP: return 49280
        case .grandMA3: return 8000
        case .chamsysMagicQ: return 8000
        case .etcEos: return 3032
        case .artNet: return 6454
        }
    }

    /// Model choices, where the driver needs to know.
    public var variants: [Variant] {
        switch self {
        case .allenHeathDLive:
            return [Variant("mixrack", "MixRack (port 51325)"), Variant("surface", "Surface (port 51328)")]
        case .yamahaRCP:
            return [Variant("tf", "TF"), Variant("dm3", "DM3"), Variant("clql", "CL / QL"), Variant("dm7", "DM7")]
        default:
            return []
        }
    }

    public struct Variant: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String

        init(_ id: String, _ title: String) {
            self.id = id
            self.title = title
        }
    }

    public var usesMIDIChannel: Bool {
        self == .allenHeathSQ || self == .allenHeathDLive
    }

    /// Executors/playbacks/faders shown as a numbered range.
    public var usesPlaybackRange: Bool {
        self == .grandMA3 || self == .chamsysMagicQ || self == .etcEos
    }

    /// What to set up on the console itself before connecting.
    public var setupSteps: [String] {
        switch self {
        case .behringerX32:
            return [
                "Put the X32 and this device on the same network (Setup › Network on the desk).",
                "Enter the desk's IP. Port 10023 is fixed.",
                "Nothing else to enable: the X32 answers OSC out of the box."
            ]
        case .behringerXAir:
            return [
                "Join the mixer's network, or put it on yours (X Air Edit › Setup › Network).",
                "Enter the mixer's IP. Port 10024 is fixed."
            ]
        case .allenHeathSQ:
            return [
                "On the SQ: Setup › Control › MIDI. Note the MIDI channel (default 1).",
                "Set NRPN Fader Law to Linear Taper. The app assumes it.",
                "Enter the SQ's IP. Port 51325."
            ]
        case .allenHeathDLive:
            return [
                "Connect to the MixRack (port 51325) or the Surface (port 51328).",
                "On the Surface: Utility › Control › MIDI. Note the MIDI channel (1–12); the protocol uses it and the four after it.",
                "The app uses the unencrypted port. The encrypted one needs a user and password and isn't supported."
            ]
        case .yamahaRCP:
            return [
                "Pick the console family, then enter its IP. Port 49280 is fixed.",
                "Works with the console itself, not with the offline Editor.",
                "Channel counts follow the largest model in the family; strips a smaller model lacks just won't answer."
            ]
        case .grandMA3:
            return [
                "Menu › In & Out › OSC. Turn on Enable Input (and Enable Output for feedback).",
                "Add a line: Destination IP = this device, Port = the app's port (8000), Prefix = the app's prefix (gma3).",
                "Turn on Receive and Receive Command. Turn on Send and set its port to the app's Feedback port to see desk moves.",
                "Set Fader Range on the line to match the app (100)."
            ]
        case .chamsysMagicQ:
            return [
                "Setup › View Settings › Network: set OSC RX port to the app's port (8000), OSC TX port to the app's Feedback port (9000), and the TX IP to this device.",
                "OSC only drives playbacks 1–10. Not available on MQ40/MQ40N, and on PC only when unlocked."
            ]
        case .etcEos:
            return [
                "Setup › System › Show Control › OSC: turn on OSC RX and OSC TX.",
                "Set OSC TCP Format to OSC 1.0 (the default). The app connects to TCP port 3032.",
                "Pick an OSC user number other than the main desk's (e.g. 2) so the app has its own command line."
            ]
        case .artNet:
            return [
                "Enter your Art-Net node's IP and the universe its DMX output is set to.",
                "The app becomes the lighting controller: each fader is one DMX channel.",
                "Use a wired link to the node if you can; Wi-Fi drops make lights flicker."
            ]
        }
    }
}
