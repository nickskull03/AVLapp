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
    /// `true` means switched in: EQ on, gate on, high-pass on.
    case enable
}

/// The range and feel of an adjustable setting, like an EQ frequency or a gate
/// threshold. Values travel as `.level(position)` with position 0...1; the
/// spec turns that into real units for display and for drivers.
public struct ParameterSpec: Equatable, Sendable {
    public enum Curve: Equatable, Sendable {
        case linear
        /// Equal steps are equal ratios, as for frequencies and times.
        case logarithmic
    }

    /// The value at position 0. May be larger than `max` (a Q that narrows as you turn up).
    public let min: Double
    /// The value at position 1.
    public let max: Double
    public let unit: String
    public let curve: Curve
    public let decimals: Int

    public init(_ min: Double, _ max: Double, unit: String = "", curve: Curve = .linear, decimals: Int = 1) {
        self.min = min
        self.max = max
        self.unit = unit
        self.curve = curve
        self.decimals = decimals
    }

    public func value(at position: Double) -> Double {
        let p = Swift.min(1, Swift.max(0, position))
        switch curve {
        case .linear:
            return min + (max - min) * p
        case .logarithmic:
            guard min > 0, max > 0 else { return min + (max - min) * p }
            return min * pow(max / min, p)
        }
    }

    public func position(for value: Double) -> Double {
        let p: Double
        switch curve {
        case .linear:
            p = max == min ? 0 : (value - min) / (max - min)
        case .logarithmic:
            guard min > 0, max > 0, value > 0, max != min else { return 0 }
            p = log(value / min) / log(max / min)
        }
        return Swift.min(1, Swift.max(0, p))
    }

    public func text(at position: Double) -> String {
        var v = value(at: position)
        var unit = self.unit
        if unit == "Hz" && abs(v) >= 1000 {
            v /= 1000
            unit = "kHz"
        }
        let digits = unit == "kHz" ? 2 : decimals
        let number = String(format: "%.\(digits)f", v)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
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
    /// Sends a line of text. The hint says what to type.
    case command(hint: String)
    /// An adjustable setting: EQ, dynamics, gain, a knob.
    case parameter(ParameterSpec)
    /// One of a list, sent as `.number(index)`.
    case choice([String])
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

/// Settings that belong together in a strip's detail, like "EQ" or "Gate".
public struct ControlSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let controls: [ControlDescriptor]
    /// Shown under the title, e.g. what the console can't do.
    public let note: String?
    /// For an EQ section: which controls are which band, so it can be drawn as a curve.
    public let eq: EQLayout?

    public init(id: String, title: String, controls: [ControlDescriptor], note: String? = nil, eq: EQLayout? = nil) {
        self.id = id
        self.title = title
        self.controls = controls
        self.note = note
        self.eq = eq
    }
}

/// The shape of an EQ band's filter.
public enum FilterShape: String, Sendable {
    case peak, lowShelf, highShelf, lowCut, highCut
}

/// One EQ band: the controls behind it, so the curve can be drawn and dragged.
public struct EQBand: Equatable, Sendable {
    public let label: String
    public let frequency: ControlID
    /// nil for bands with no gain (cuts).
    public let gain: ControlID?
    /// A `.parameter` (Q), or a `.choice` of bandwidths in octaves when `qIsOctaves`.
    public let q: ControlID?
    public let qIsOctaves: Bool
    /// A `.choice` picking the band's shape; nil when it has one shape.
    public let type: ControlID?
    /// The shape for each of the type's options, or the one shape when there's no type.
    public let shapes: [FilterShape]

    public init(label: String, frequency: ControlID, gain: ControlID?, q: ControlID?, qIsOctaves: Bool = false,
                type: ControlID? = nil, shapes: [FilterShape]) {
        self.label = label
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.qIsOctaves = qIsOctaves
        self.type = type
        self.shapes = shapes
    }
}

public struct EQLayout: Equatable, Sendable {
    /// The EQ's on switch, if it has one.
    public let on: ControlID?
    public let bands: [EQBand]

    public init(on: ControlID?, bands: [EQBand]) {
        self.on = on
        self.bands = bands
    }
}

public enum StripStyle: String, Sendable {
    case input, fx, bus, master, dca, muteGroup, playback, dimmer
}

/// A channel strip, playback column or dimmer.
///
///     name
///     gain             (on the strip, if any)
///     buttons          (above the fader)
///     fader | meters
///     lowerButtons     (under the fader)
///
/// `sections` hold the rest (EQ, dynamics, cue tools), shown in the strip's detail.
public struct Strip: Identifiable, Equatable, Sendable {
    /// Unique within the device, e.g. "ch.1".
    public let id: String
    public let defaultName: String
    public let style: StripStyle
    public let fader: ControlDescriptor?
    public let buttons: [ControlDescriptor]
    public let lowerButtons: [ControlDescriptor]
    public let gain: ControlDescriptor?
    public let sections: [ControlSection]
    /// The console reports signal levels for this strip.
    public let hasInputMeter: Bool
    public let hasOutputMeter: Bool

    public init(id: String, name: String, style: StripStyle, fader: ControlDescriptor?,
                buttons: [ControlDescriptor] = [], lowerButtons: [ControlDescriptor] = [],
                gain: ControlDescriptor? = nil, sections: [ControlSection] = [],
                hasInputMeter: Bool = false, hasOutputMeter: Bool = false) {
        self.id = id
        self.defaultName = name
        self.style = style
        self.fader = fader
        self.buttons = buttons
        self.lowerButtons = lowerButtons
        self.gain = gain
        self.sections = sections
        self.hasInputMeter = hasInputMeter
        self.hasOutputMeter = hasOutputMeter
    }

    /// Everything on the strip and in its detail.
    public var controls: [ControlDescriptor] {
        (fader.map { [$0] } ?? []) + (gain.map { [$0] } ?? []) + buttons + lowerButtons + sections.flatMap(\.controls)
    }
}

/// Signal levels for a strip, as positions on a meter (0 = −60 dB or below, 1 = 0 dBFS).
public struct MeterReading: Equatable, Sendable {
    public var input: Double?
    public var output: Double?

    public init(input: Double? = nil, output: Double? = nil) {
        self.input = input
        self.output = output
    }

    /// The meter scale the app draws: −60 dB to 0 dBFS.
    public static func position(decibels: Double) -> Double {
        Swift.min(1, Swift.max(0, (decibels + 60) / 60))
    }

    /// From a linear amplitude (1.0 = 0 dBFS).
    public static func position(amplitude: Double) -> Double {
        amplitude <= 0 ? 0 : position(decibels: 20 * log10(amplitude))
    }
}

/// How the user has made a strip their own: saved with the device.
public struct StripCustomization: Codable, Equatable, Sendable {
    public var name: String?
    /// One of `StripCustomization.colors`.
    public var color: String?
    /// Control ID → action ID, for consoles whose buttons can do different things.
    public var actions: [String: String]

    public init(name: String? = nil, color: String? = nil, actions: [String: String] = [:]) {
        self.name = name
        self.color = color
        self.actions = actions
    }

    public static let colors = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "white"]

    public var isEmpty: Bool { (name ?? "").isEmpty && color == nil && actions.isEmpty }
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
    /// Said once in a strip's detail, e.g. "SQ's MIDI protocol has no EQ or dynamics."
    public var note: String?
    /// What a button can be set to do, as (action ID, label), for consoles that
    /// support it. Empty: buttons always do what the console has them do.
    public var buttonActions: [ButtonAction]

    public init(reportsChanges: Bool, readsNames: Bool, note: String? = nil, buttonActions: [ButtonAction] = []) {
        self.reportsChanges = reportsChanges
        self.readsNames = readsNames
        self.note = note
        self.buttonActions = buttonActions
    }
}

public struct ButtonAction: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }
}
