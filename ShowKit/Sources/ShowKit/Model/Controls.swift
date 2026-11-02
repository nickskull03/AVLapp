import Foundation

/// Lights or sound.
public enum Domain: String, Codable, Sendable {
    case lighting
    case audio
}

/// One control on one device, e.g. "ch.1.level". IDs are stable across
/// launches, so cues saved today still find their controls tomorrow.
public struct ControlID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// A value sent to or reported by a control. Switches are always sent as an
/// explicit state, never as "toggle", so a lost or repeated message can't
/// leave the app and the console disagreeing.
public enum ControlValue: Equatable, Codable, Sendable {
    /// Fader position, 0...1 of travel. For audio this follows `AudioTaper`.
    case level(Double)
    /// A switch. What `true` means depends on the control's `ToggleRole`.
    case on(Bool)
    /// A one-shot, like Go.
    case trigger
    /// A key held down (`true`) or released (`false`), like Flash.
    case press(Bool)
    /// A number, like a scene to recall.
    case number(Int)
    /// A command line for the console.
    case text(String)

    public var level: Double? {
        if case .level(let v) = self { return v }
        return nil
    }

    public var isOn: Bool? {
        if case .on(let v) = self { return v }
        return nil
    }
}

public enum LevelUnit: String, Codable, Sendable {
    /// Shown as 0–100%.
    case percent
    /// Shown in dB along `AudioTaper`, with a 0 dB mark.
    case decibels
}

public enum ToggleRole: String, Sendable {
    /// `true` means muted (silent).
    case mute
    /// `true` means all lights out.
    case blackout
}

public enum ControlKind: Equatable, Sendable {
    case fader(LevelUnit)
    case toggle(ToggleRole)
    /// Fires once per tap.
    case trigger
    /// Sends press and release.
    case momentary
    /// Sends a number from the range, e.g. a scene.
    case number(ClosedRange<Int>)
    /// Sends a line of text.
    case command
}

public struct ControlDescriptor: Identifiable, Equatable, Sendable {
    public let id: ControlID
    public let label: String
    public let kind: ControlKind
    /// Ask before sending: scene recalls, mains mutes, blackouts.
    public let needsConfirmation: Bool

    public init(_ id: ControlID, _ label: String, _ kind: ControlKind, needsConfirmation: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.needsConfirmation = needsConfirmation
    }
}

public enum StripStyle: String, Sendable {
    case input, fx, bus, master, dca, muteGroup, playback, dimmer
}

/// A channel strip, playback or dimmer: one fader and the buttons that go with it.
public struct Strip: Identifiable, Equatable, Sendable {
    /// Unique within the device, e.g. "ch.1".
    public let id: String
    public let defaultName: String
    public let style: StripStyle
    public let fader: ControlDescriptor?
    /// Shown above the fader, top to bottom.
    public let buttons: [ControlDescriptor]

    public init(id: String, name: String, style: StripStyle, fader: ControlDescriptor?, buttons: [ControlDescriptor] = []) {
        self.id = id
        self.defaultName = name
        self.style = style
        self.fader = fader
        self.buttons = buttons
    }

    public var controls: [ControlDescriptor] {
        (fader.map { [$0] } ?? []) + buttons
    }
}

/// Strips that belong together, like "Inputs" or "DCAs".
public struct StripGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let strips: [Strip]

    public init(id: String, title: String, strips: [Strip]) {
        self.id = id
        self.title = title
        self.strips = strips
    }
}

public enum LinkState: Equatable, Sendable {
    case disconnected
    case connecting
    /// The console answers.
    case connected
    /// Messages go out, but this protocol can't tell whether anyone hears them.
    case sending
    case failed(String)

    public var isUsable: Bool {
        self == .connected || self == .sending
    }

    public var label: String {
        switch self {
        case .disconnected: return "Offline"
        case .connecting: return "Connecting…"
        case .connected: return "Online"
        case .sending: return "Sending"
        case .failed(let reason): return reason
        }
    }
}

/// What a driver can and can't do, so the UI can say so instead of pretending.
public struct DriverTraits: Equatable, Sendable {
    /// The console reports changes made elsewhere (at the desk, by other apps).
    public var reportsChanges: Bool
    /// Strip names come from the console.
    public var readsNames: Bool

    public init(reportsChanges: Bool, readsNames: Bool) {
        self.reportsChanges = reportsChanges
        self.readsNames = readsNames
    }
}
