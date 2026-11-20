import Foundation

/// A compressor or gate section, read for what each of its controls does, so
/// it can be drawn as a transfer curve with knobs instead of a list of sliders.
///
/// Drivers don't have to describe this: `DynamicsLayout(section:)` works it
/// out from the section's id ("comp", "gate", "dyn…") and its controls'
/// labels and ids (Threshold, Ratio, Knee, Attack, …), which every driver
/// names the same way.
public struct DynamicsLayout: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case compressor, gate }

    public let kind: Kind
    public var on: ControlID?
    public var threshold: ControlID?
    /// A `.parameter`, or a `.choice` of ratios ("4:1", "∞").
    public var ratio: ControlID?
    /// Gate: how far below the signal is turned down when closed.
    public var range: ControlID?
    public var knee: ControlID?
    /// Make-up gain (compressor) or output gain.
    public var makeup: ControlID?
    public var attack: ControlID?
    public var hold: ControlID?
    public var release: ControlID?
    public var mix: ControlID?

    public init(kind: Kind) {
        self.kind = kind
    }

    /// The controls drawn on the graph or as knobs; the rest stay in the list.
    public var handled: Set<ControlID> {
        Set([on, threshold, ratio, range, knee, makeup, attack, hold, release, mix].compactMap { $0 })
    }

    /// The knobs under the graph, in order.
    public var knobs: [ControlID] {
        [attack, hold, release, knee, makeup, mix].compactMap { $0 }
    }

    /// nil when the section isn't dynamics, or has no threshold to draw.
    public init?(section: ControlSection) {
        let title = section.title.lowercased()
        let id = section.id.lowercased()
        if id.contains("gate") || title.contains("gate") || title.contains("expander") {
            kind = .gate
        } else if id.contains("comp") || id.contains("dyn") || title.contains("compressor") || title.contains("dynamics") {
            kind = .compressor
        } else {
            return nil
        }
        for control in section.controls {
            switch Self.role(of: control) {
            case "on": on = on ?? control.id
            case "threshold": threshold = threshold ?? control.id
            case "ratio": ratio = ratio ?? control.id
            case "range": range = range ?? control.id
            case "knee": knee = knee ?? control.id
            case "makeup": makeup = makeup ?? control.id
            case "attack": attack = attack ?? control.id
            case "hold": hold = hold ?? control.id
            case "release": release = release ?? control.id
            case "mix": mix = mix ?? control.id
            default: break
            }
        }
        guard threshold != nil else { return nil }
    }

    /// What a control is, from its label first and its id's last word second.
    static func role(of control: ControlDescriptor) -> String? {
        let label = control.label.lowercased()
        let last = control.id.rawValue.split(separator: ".").last.map { $0.lowercased() } ?? ""
        switch control.kind {
        case .toggle:
            return label.hasSuffix(" on") || last == "on" ? "on" : nil
        case .parameter, .choice:
            break
        default:
            return nil
        }
        let words: [(String, [String])] = [
            ("threshold", ["threshold", "thr", "thresh"]),
            ("ratio", ["ratio"]),
            ("range", ["range", "depth"]),
            ("knee", ["knee"]),
            ("makeup", ["make-up", "makeup", "make up", "mgain", "outgain", "gain"]),
            ("attack", ["attack", "att"]),
            ("hold", ["hold", "hld"]),
            ("release", ["release", "rel", "decay"]),
            ("mix", ["mix"])
        ]
        for (role, keys) in words where keys.contains(where: { label.contains($0) }) { return role }
        for (role, keys) in words where keys.contains(last) { return role }
        return nil
    }

    // MARK: Numbers for drawing

    /// "4:1" → 4, "1.5" → 1.5, "∞" or "inf" → .infinity.
    public static func number(fromOption text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("∞") || t.hasPrefix("inf") || t.hasPrefix("lim") { return .infinity }
        let head = t.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(head)
    }

    /// Output level for an input level (both dB) through a compressor.
    public static func compressed(_ input: Double, threshold: Double, ratio: Double, knee: Double, makeup: Double) -> Double {
        let r = max(1, ratio)
        let slope = r.isInfinite ? 0 : 1 / r
        let k = max(0, knee)
        let over = input - threshold
        let out: Double
        if k > 0 && abs(over) <= k / 2 {
            // Soft knee: a quadratic between the two straight lines.
            out = input + (slope - 1) * pow(over + k / 2, 2) / (2 * k)
        } else if over > 0 {
            out = threshold + over * slope
        } else {
            out = input
        }
        return out + makeup
    }

    /// Output level for an input level (both dB) through a gate: below the
    /// threshold, turned down by `range` dB.
    public static func gated(_ input: Double, threshold: Double, range: Double) -> Double {
        input >= threshold ? input : input - abs(range)
    }
}
