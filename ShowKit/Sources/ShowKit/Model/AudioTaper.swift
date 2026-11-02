import Foundation

/// The fader law every audio fader in the app uses: 0 dB at 75% of travel,
/// +10 dB at the top, −∞ at the bottom, in four straight-in-dB segments. It's
/// the Behringer X32's law, so X32 values pass through unchanged, and it feels
/// like a console fader on every other mixer too. Drivers convert dB to and
/// from their own wire values.
public enum AudioTaper {
    /// Lowest dB above −∞.
    public static let floor = -90.0
    public static let ceiling = 10.0
    public static let unity = position(decibels: 0)

    /// dB for a fader position; nil is −∞.
    public static func decibels(position: Double) -> Double? {
        let f = min(1, max(0, position))
        if f <= 0 { return nil }
        if f >= 0.5 { return 40 * f - 30 }
        if f >= 0.25 { return 80 * f - 50 }
        if f >= 0.0625 { return 160 * f - 70 }
        return 480 * f - 90
    }

    /// Fader position for a dB value; nil (−∞) or anything at or below `floor` is 0.
    public static func position(decibels: Double?) -> Double {
        guard let d = decibels, d > floor else { return 0 }
        if d >= ceiling { return 1 }
        if d < -60 { return (d + 90) / 480 }
        if d < -30 { return (d + 70) / 160 }
        if d < -10 { return (d + 50) / 80 }
        return (d + 30) / 40
    }

    public static func text(position: Double) -> String {
        guard let d = decibels(position: position) else { return "−∞" }
        let rounded = (d * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        if rounded > 0 { return String(format: "+%.1f", rounded) }
        return String(format: rounded <= -10 ? "%.0f" : "%.1f", rounded)
    }
}
