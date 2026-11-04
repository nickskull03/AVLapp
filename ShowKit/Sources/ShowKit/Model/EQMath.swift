import Foundation

/// The response of EQ bands, for drawing the curve. Each band is the standard
/// biquad from Robert Bristow-Johnson's "Audio EQ Cookbook" at 48 kHz, which is
/// close to what digital consoles do, though their own curves differ in detail.
public enum EQMath {
    public static let sampleRate = 48_000.0
    public static let lowest = 20.0
    public static let highest = 20_000.0

    /// Q for a bandwidth in octaves.
    public static func q(octaves: Double) -> Double {
        guard octaves > 0 else { return 1 }
        let p = pow(2, octaves)
        return sqrt(p) / (p - 1)
    }

    /// `count` frequencies spaced evenly on a log scale from 20 Hz to 20 kHz.
    public static func frequencies(count: Int) -> [Double] {
        guard count > 1 else { return [1000] }
        return (0..<count).map { lowest * pow(highest / lowest, Double($0) / Double(count - 1)) }
    }

    /// 0...1 across the graph for a frequency, and back.
    public static func position(frequency: Double) -> Double {
        log(max(lowest, min(highest, frequency)) / lowest) / log(highest / lowest)
    }

    public static func frequency(position: Double) -> Double {
        lowest * pow(highest / lowest, max(0, min(1, position)))
    }

    /// The band's gain in dB at `frequency`.
    public static func response(shape: FilterShape, center: Double, gain: Double, q: Double, at frequency: Double) -> Double {
        let f0 = min(max(center, 10), sampleRate * 0.49)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let a = pow(10, gain / 40)
        let rootA2Alpha = 2 * sqrt(a) * alpha

        let (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
        switch shape {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * cosw, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * cosw, 1 - alpha / a)
        case .lowShelf:
            b0 = a * ((a + 1) - (a - 1) * cosw + rootA2Alpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - rootA2Alpha)
            a0 = (a + 1) + (a - 1) * cosw + rootA2Alpha
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - rootA2Alpha
        case .highShelf:
            b0 = a * ((a + 1) + (a - 1) * cosw + rootA2Alpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - rootA2Alpha)
            a0 = (a + 1) - (a - 1) * cosw + rootA2Alpha
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - rootA2Alpha
        case .lowCut:
            (b0, b1, b2) = ((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        case .highCut:
            (b0, b1, b2) = ((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * cosw, 1 - alpha)
        }

        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numerator = pow(b0 + b1 * c1 + b2 * c2, 2) + pow(b1 * s1 + b2 * s2, 2)
        let denominator = pow(a0 + a1 * c1 + a2 * c2, 2) + pow(a1 * s1 + a2 * s2, 2)
        guard numerator > 0, denominator > 0 else { return -120 }
        return 10 * log10(numerator / denominator)
    }
}
