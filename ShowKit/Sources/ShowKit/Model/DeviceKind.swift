import Foundation

/// A console family the app has a driver for.
public enum DeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Sound
    case behringerX32
    case behringerXAir
    case behringerWing
    case allenHeathSQ
    /// The current Qu (2025 on): Qu-5, Qu-6, Qu-7 and their D versions.
    case allenHeathQu
    /// The original Qu (2013–2024): Qu-16, Qu-24, Qu-32, Qu-Pac, Qu-SB.
    case allenHeathQuClassic
    case allenHeathDLive
    case yamahaRCP
    // Lights
    case grandMA3
    case chamsysMagicQ
    case etcEos
    case lightingConsole
    case artNet
    // Built in, for trying the app without a network
    case demoAudio
    case demoLighting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .behringerX32: return "Behringer X32 / Midas M32"
        case .behringerXAir: return "Behringer X Air / Midas MR"
        case .behringerWing: return "Behringer Wing"
        case .allenHeathSQ: return "Allen & Heath SQ"
        case .allenHeathQu: return "Allen & Heath Qu-5 / Qu-6 / Qu-7 (new Qu)"
        case .allenHeathQuClassic: return "Allen & Heath Qu-16 / 24 / 32 / Pac / SB (original Qu)"
        case .allenHeathDLive: return "Allen & Heath dLive / Avantis"
        case .yamahaRCP: return "Yamaha TF / DM3 / CL / QL / DM7"
        case .grandMA3: return "grandMA3"
        case .chamsysMagicQ: return "ChamSys MagicQ"
        case .etcEos: return "ETC Eos family"
        case .lightingConsole: return "Lighting (desktop console)"
        case .artNet: return "Lights direct (Art-Net DMX)"
        case .demoAudio: return "Demo mixer (offline)"
        case .demoLighting: return "Demo lighting console (offline)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .behringerX32: return "X32"
        case .behringerXAir: return "X Air"
        case .behringerWing: return "Wing"
        case .allenHeathSQ: return "SQ"
        case .allenHeathQu: return "Qu"
        case .allenHeathQuClassic: return "Qu"
        case .allenHeathDLive: return "dLive"
        case .yamahaRCP: return "Yamaha"
        case .grandMA3: return "MA3"
        case .chamsysMagicQ: return "MagicQ"
        case .etcEos: return "Eos"
        case .lightingConsole: return "Lighting"
        case .artNet: return "DMX"
        case .demoAudio: return "Demo mixer"
        case .demoLighting: return "Demo lights"
        }
    }

    public var domain: Domain {
        switch self {
        case .behringerX32, .behringerXAir, .behringerWing, .allenHeathSQ, .allenHeathQu, .allenHeathQuClassic, .allenHeathDLive, .yamahaRCP, .demoAudio:
            return .audio
        case .grandMA3, .chamsysMagicQ, .etcEos, .lightingConsole, .artNet, .demoLighting: return .lighting
        }
    }

    public var defaultPort: Int {
        switch self {
        case .behringerX32: return 10023
        case .behringerXAir: return 10024
        case .behringerWing: return 2223
        case .allenHeathSQ, .allenHeathQu, .allenHeathQuClassic: return 51325
        case .allenHeathDLive: return 51325 // MixRack; the Surface is 51328
        case .yamahaRCP: return 49280
        case .grandMA3: return 8000
        case .chamsysMagicQ: return 8000
        case .etcEos: return 3032
        case .lightingConsole: return 8080
        case .artNet: return 6454
        case .demoAudio, .demoLighting: return 0
        }
    }

    /// Model choices, where the driver needs to know.
    public var variants: [Variant] {
        switch self {
        case .allenHeathDLive:
            return [Variant("mixrack", "MixRack (port 51325)"), Variant("surface", "Surface (port 51328)")]
        case .allenHeathQuClassic:
            return [Variant("qu16", "Qu-16"), Variant("qu24", "Qu-24"), Variant("qu32", "Qu-32 / Qu-Pac / Qu-SB")]
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

    /// Lives inside the app: no IP, no network, nothing to set up.
    public var isDemo: Bool {
        self == .demoAudio || self == .demoLighting
    }

    public var usesMIDIChannel: Bool {
        self == .allenHeathSQ || self == .allenHeathQu || self == .allenHeathQuClassic || self == .allenHeathDLive
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
        case .behringerWing:
            return [
                "Enter the Wing's IP (Setup › Network on the console). Port 2223 is fixed.",
                "The Wing sends its changes to one app at a time: close Companion or other OSC apps that subscribe to it."
            ]
        case .allenHeathSQ:
            return [
                "On the SQ: Setup › Control › MIDI. Note the MIDI channel (default 1).",
                "Set NRPN Fader Law to Linear Taper. The app assumes it.",
                "Enter the SQ's IP. Port 51325."
            ]
        case .allenHeathQu:
            return [
                "On the Qu: Utility › General › MIDI. Note the MIDI channel (default 1).",
                "Set NRPN Fader Law to Linear Taper. The app assumes it.",
                "Enter the Qu's IP (Utility › Network). Port 51325.",
                "For the Qu-16, 24, 32, Pac or SB, add \"Qu-16 / 24 / 32 / Pac / SB\" instead: the original Qu speaks a different protocol."
            ]
        case .allenHeathQuClassic:
            return [
                "Pick your model, then enter the Qu's IP (Setup › Network). Port 51325.",
                "On the Qu: Setup › Control › MIDI. Note the MIDI channel (default 1); DAW control uses the one after it.",
                "Qu takes one network MIDI connection at a time: close Qu-Pad's MIDI, Companion or other MIDI apps first. Qu-Pad and Qu-You themselves can stay connected.",
                "For the Qu-5, Qu-6 or Qu-7, add \"Qu-5 / Qu-6 / Qu-7\" instead."
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
                "Turn on Receive and Receive Command, and Send to see desk moves. A line uses one port both ways, so the app's Feedback port must match it (8000).",
                "Set Fader Range on the line to match the app (100).",
                "Optional: run the Show Deck plugin on the console (see MA3/README.md) to see executor names, running keys, current cues and the desk's page in the app."
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
        case .lightingConsole:
            return [
                "Start the console so other devices can reach it: run \"npm start -- --host 0.0.0.0\" on the computer running it (the desktop app only listens on that computer).",
                "Enter that computer's IP and the console's port (8080 unless you changed it).",
                "There's no login: only do this on a network you trust."
            ]
        case .demoAudio:
            return [
                "Nothing to set up: this mixer lives inside the app, so you can try everything with no network.",
                "Faders, mutes, gain, EQ, gate and compressor all work, and the meters move with a made-up signal."
            ]
        case .demoLighting:
            return [
                "Nothing to set up: this console lives inside the app, so you can try everything with no network.",
                "Ten sequences with cues: Go steps through them, Flash and Off work, and the key panel takes commands."
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
