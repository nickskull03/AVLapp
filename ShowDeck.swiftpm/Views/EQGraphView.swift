import ShowKit
import SwiftUI

/// A parametric EQ as a curve you can play: drag a band's point left and right
/// for frequency, up and down for gain, and pinch for Q (or width). The exact
/// values are in the list below it.
struct EQGraphView: View {
    let device: Device
    let layout: EQLayout
    /// The section's controls, for each band control's range and options.
    let controls: [ControlDescriptor]

    @State private var selected: Int?
    @State private var dragging = false
    @State private var pinchStart: Double?

    private static let range = 18.0 // ± dB shown

    // MARK: Reading the console's values

    private func spec(_ id: ControlID?) -> ParameterSpec? {
        guard let id, let control = controls.first(where: { $0.id == id }), case .parameter(let spec) = control.kind else { return nil }
        return spec
    }

    private func options(_ id: ControlID?) -> [String] {
        guard let id, let control = controls.first(where: { $0.id == id }), case .choice(let options) = control.kind else { return [] }
        return options
    }

    private func position(_ id: ControlID?) -> Double? {
        guard let id else { return nil }
        return device.control(id).value?.level
    }

    private func index(_ id: ControlID?) -> Int? {
        guard let id, case .number(let i)? = device.control(id).value else { return nil }
        return i
    }

    struct BandValues {
        var frequency: Double
        var gain: Double
        var q: Double
        var shape: FilterShape
        var hasGain: Bool { shape != .lowCut && shape != .highCut }
    }

    private func values(_ band: EQBand) -> BandValues {
        let frequency = spec(band.frequency).map { $0.value(at: position(band.frequency) ?? 0.5) } ?? 1000
        let gain = spec(band.gain).map { $0.value(at: position(band.gain) ?? 0.5) } ?? 0
        var q = 0.707
        if band.qIsOctaves {
            if let i = index(band.q), let octaves = Double(options(band.q)[safe: i] ?? "") { q = EQMath.q(octaves: octaves) }
        } else if let qSpec = spec(band.q) {
            q = qSpec.value(at: position(band.q) ?? 0.5)
        }
        let typeIndex = index(band.type) ?? 0
        let shape = band.shapes[safe: typeIndex] ?? band.shapes.first ?? .peak
        return BandValues(frequency: frequency, gain: gain, q: q, shape: shape)
    }

    private var isOn: Bool {
        guard let on = layout.on else { return true }
        return device.control(on).value?.isOn ?? true
    }

    // MARK: Drawing

    var body: some View {
        let bands = layout.bands.map(values)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { context, size in
                        drawGrid(context, size)
                        drawCurve(context, size, bands: bands)
                    }
                    ForEach(bands.indices, id: \.self) { i in
                        let point = self.point(bands[i], size)
                        Circle()
                            .fill(selected == i ? Color.accentColor : Color.orange.opacity(0.85))
                            .frame(width: selected == i ? 30 : 24, height: selected == i ? 30 : 24)
                            .overlay(Text(layout.bands[i].label).font(.caption2.weight(.bold)).foregroundStyle(.white))
                            .position(point)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(size, bands: bands))
                .simultaneousGesture(pinch(bands: bands))
            }
            .frame(height: 220)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isOn ? 1 : 0.5)
            .disabled(!device.isLive)

            if let i = selected, layout.bands.indices.contains(i) {
                let v = bands[i]
                Text(readout(layout.bands[i], v))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(isOn ? "Drag a point to move a band; pinch to change its width." : "EQ is off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EQ curve")
        .accessibilityValue(layout.bands.indices.map { readout(layout.bands[$0], bands[$0]) }.joined(separator: "; "))
    }

    private func readout(_ band: EQBand, _ v: BandValues) -> String {
        let hz = v.frequency >= 1000 ? String(format: "%.2f kHz", v.frequency / 1000) : String(format: "%.0f Hz", v.frequency)
        var parts = ["Band \(band.label)", hz]
        if v.hasGain { parts.append(String(format: "%+.1f dB", v.gain)) }
        parts.append(String(format: "Q %.2f", v.q))
        return parts.joined(separator: " · ")
    }

    private func point(_ v: BandValues, _ size: CGSize) -> CGPoint {
        let x = EQMath.position(frequency: v.frequency) * size.width
        let gain = v.hasGain ? v.gain : 0
        let y = size.height / 2 - gain / Self.range * size.height / 2
        return CGPoint(x: x, y: min(max(y, 12), size.height - 12))
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for db in stride(from: -12.0, through: 12, by: 6) {
            let y = size.height / 2 - db / Self.range * size.height / 2
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let x = EQMath.position(frequency: hz) * size.width
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
        for (hz, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            let x = EQMath.position(frequency: hz) * size.width
            context.draw(Text(label).font(.caption2).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: x + 12, y: size.height - 8))
        }
        for db in [12.0, -12] {
            let y = size.height / 2 - db / Self.range * size.height / 2
            context.draw(Text(String(format: "%+.0f", db)).font(.caption2).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: 14, y: y - 7))
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize, bands: [BandValues]) {
        let frequencies = EQMath.frequencies(count: max(64, Int(size.width / 3)))
        var curve = Path()
        for (i, f) in frequencies.enumerated() {
            let db = bands.reduce(0.0) { $0 + EQMath.response(shape: $1.shape, center: $1.frequency, gain: $1.gain, q: $1.q, at: f) }
            let x = EQMath.position(frequency: f) * size.width
            let y = size.height / 2 - max(-Self.range * 1.5, min(Self.range * 1.5, db)) / Self.range * size.height / 2
            if i == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
        fill.closeSubpath()
        context.fill(fill, with: .color(.orange.opacity(0.15)))
        context.stroke(curve, with: .color(.orange), lineWidth: 2)
    }

    // MARK: Gestures

    private func nearestBand(to location: CGPoint, _ size: CGSize, bands: [BandValues]) -> Int? {
        let distances = bands.indices.map { i -> (Int, CGFloat) in
            let p = point(bands[i], size)
            return (i, hypot(p.x - location.x, p.y - location.y))
        }
        return distances.min { $0.1 < $1.1 }.flatMap { $0.1 < 60 ? $0.0 : nil }
    }

    private func touch(_ band: EQBand, _ touching: Bool) {
        device.touch(band.frequency, touching)
        if let gain = band.gain { device.touch(gain, touching) }
    }

    private func drag(_ size: CGSize, bands: [BandValues]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !dragging {
                    dragging = true
                    selected = nearestBand(to: drag.startLocation, size, bands: bands) ?? selected
                    if let i = selected { touch(layout.bands[i], true) }
                }
                guard let i = selected, size.width > 0 else { return }
                let band = layout.bands[i]
                if let freqSpec = spec(band.frequency) {
                    let hz = EQMath.frequency(position: Double(drag.location.x / size.width))
                    device.setLevel(band.frequency, freqSpec.position(for: hz))
                }
                if bands[i].hasGain, let gainID = band.gain, let gainSpec = spec(gainID) {
                    let db = (Double(size.height / 2 - drag.location.y) / Double(size.height / 2)) * Self.range
                    device.setLevel(gainID, gainSpec.position(for: db))
                }
            }
            .onEnded { _ in
                if let i = selected { touch(layout.bands[i], false) }
                dragging = false
            }
    }

    private func pinch(bands: [BandValues]) -> some Gesture {
        MagnifyGesture()
            .onChanged { pinch in
                guard let i = selected else { return }
                let band = layout.bands[i]
                if pinchStart == nil {
                    pinchStart = bands[i].q
                    if let q = band.q { device.touch(q, true) }
                }
                guard let qID = band.q, let start = pinchStart else { return }
                // Spreading the fingers widens the band: a lower Q.
                let q = start / Double(pinch.magnification)
                if band.qIsOctaves {
                    let widths = options(qID).compactMap(Double.init)
                    let target = log2(1 / q + 1) // rough octaves for this Q
                    if let nearest = widths.indices.min(by: { abs(widths[$0] - target) < abs(widths[$1] - target) }),
                       nearest != index(qID) {
                        device.perform(qID, .number(nearest))
                    }
                } else if let qSpec = spec(qID) {
                    device.setLevel(qID, qSpec.position(for: q))
                }
            }
            .onEnded { _ in
                if let i = selected, let q = layout.bands[i].q { device.touch(q, false) }
                pinchStart = nil
            }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
