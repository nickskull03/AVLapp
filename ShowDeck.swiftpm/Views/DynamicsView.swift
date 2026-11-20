import ShowKit
import SwiftUI

/// A compressor or gate you can see: its transfer curve (signal in across,
/// signal out up), with the live signal riding on it, a threshold to drag
/// left and right, and the ratio (or the gate's range) to drag up and down.
/// Times and gains are knobs underneath.
struct DynamicsView: View {
    let device: Device
    let stripID: String
    let layout: DynamicsLayout
    let controls: [ControlDescriptor]

    @State private var dragging: Handle?

    enum Handle { case threshold, ratio, range }

    // MARK: Reading the console's values

    private func control(_ id: ControlID?) -> ControlDescriptor? {
        id.flatMap { id in controls.first { $0.id == id } }
    }

    /// A control's value in its own units: a parameter's value, or the number in a choice ("4:1" → 4).
    private func number(_ id: ControlID?) -> Double? {
        guard let control = control(id) else { return nil }
        switch control.kind {
        case .parameter(let spec):
            return device.control(control.id).value?.level.map { spec.value(at: $0) }
        case .choice(let options):
            guard case .number(let i)? = device.control(control.id).value, options.indices.contains(i) else { return nil }
            return DynamicsLayout.number(fromOption: options[i])
        default:
            return nil
        }
    }

    private var isOn: Bool {
        guard let on = layout.on else { return true }
        return device.control(on).value?.isOn ?? false
    }

    private var threshold: Double { number(layout.threshold) ?? (layout.kind == .gate ? -40 : -20) }
    private var ratio: Double { number(layout.ratio) ?? 4 }
    private var range: Double { abs(number(layout.range) ?? 40) }

    private var knee: Double {
        guard let control = control(layout.knee), let value = number(layout.knee) else { return 0 }
        // X32-style knees are 0–5 steps, not dB: about 2 dB a step.
        if case .parameter(let spec) = control.kind, !spec.unit.contains("dB") { return value * 2 }
        return value
    }

    private var makeup: Double {
        guard let control = control(layout.makeup), case .parameter(let spec) = control.kind, spec.unit.contains("dB") else { return 0 }
        return number(layout.makeup) ?? 0
    }

    /// Lowest level drawn: −60 dB, or lower if the threshold goes there.
    private var lowest: Double {
        guard case .parameter(let spec)? = control(layout.threshold)?.kind else { return -60 }
        return max(-90, min(-60, min(spec.min, spec.max)))
    }

    private func output(_ input: Double) -> Double {
        switch layout.kind {
        case .compressor:
            return DynamicsLayout.compressed(input, threshold: threshold, ratio: ratio, knee: knee, makeup: makeup)
        case .gate:
            return DynamicsLayout.gated(input, threshold: threshold, range: range)
        }
    }

    // MARK: Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let on = layout.on {
                    Toggle(layout.kind == .gate ? "Gate on" : "Compressor on", isOn: Binding(
                        get: { device.control(on).value?.isOn ?? false },
                        set: { device.set(on, on: $0) }
                    ))
                    .fixedSize()
                }
                Spacer()
                Text(summary)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { context, size in
                        drawGrid(context, size)
                        drawCurve(context, size)
                    }
                    MeterDot(meter: device.meterState(stripID), place: { place($0, size) })
                    ForEach(handles, id: \.self) { handle in
                        Circle()
                            .fill(dragging == handle ? Color.accentColor : tint)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .frame(width: dragging == handle ? 28 : 22, height: dragging == handle ? 28 : 22)
                            .position(position(of: handle, size))
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(size))
            }
            .aspectRatio(1.4, contentMode: .fit)
            .frame(maxWidth: 520)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isOn ? 1 : 0.5)
            .disabled(!device.isLive)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(layout.kind == .gate ? "Gate curve" : "Compressor curve")
            .accessibilityValue(summary)

            Text(layout.kind == .gate
                 ? "Drag the dot on the curve for the threshold, and the low one for how far the gate turns down."
                 : "Drag the dot on the curve for the threshold, and the end of the curve up or down for the ratio.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let knobs = layout.knobs.compactMap { control($0) }
            if !knobs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                    ForEach(knobs) { knob in
                        switch knob.kind {
                        case .parameter(let spec):
                            KnobView(device: device, control: knob, spec: spec)
                        default:
                            ControlRow(device: device, control: knob)
                        }
                    }
                }
                .disabled(!device.isLive)
            }
            if let ratio = control(layout.ratio), case .choice = ratio.kind {
                ControlRow(device: device, control: ratio)
            }
        }
    }

    private var tint: Color { layout.kind == .gate ? .teal : .orange }

    private var summary: String {
        var parts = [String(format: "Threshold %.1f dB", threshold)]
        switch layout.kind {
        case .compressor:
            parts.append(ratio.isInfinite ? "∞:1" : String(format: "%.1f:1", ratio))
            if let input = liveInput, isOn {
                let reduction = min(0, output(input) - makeup - input)
                parts.append(String(format: "GR %.1f dB", reduction))
            }
        case .gate:
            parts.append(String(format: "Range %.0f dB", range))
        }
        return parts.joined(separator: " · ")
    }

    private var liveInput: Double? {
        let reading = device.meterState(stripID).reading
        return reading.input.map { $0 * 60 - 60 }
    }

    /// Where a level pair sits on the graph.
    private func place(_ input: Double, _ output: Double, _ size: CGSize) -> CGPoint {
        let span = -lowest
        let x = (input - lowest) / span * size.width
        let y = size.height - (output - lowest) / span * size.height
        return CGPoint(x: x, y: min(max(y, 0), size.height))
    }

    /// The live signal's spot on the curve, from its input meter (nil when quiet).
    private func place(_ meter: MeterReading, _ size: CGSize) -> CGPoint? {
        guard let position = meter.input, position > 0 else { return nil }
        let input = max(lowest, position * 60 - 60)
        return place(input, isOn ? output(input) : input, size)
    }

    private var handles: [Handle] {
        var list: [Handle] = [.threshold]
        if layout.kind == .compressor, layout.ratio != nil { list.append(.ratio) }
        if layout.kind == .gate, layout.range != nil { list.append(.range) }
        return list
    }

    private func position(of handle: Handle, _ size: CGSize) -> CGPoint {
        switch handle {
        case .threshold: return place(threshold, output(threshold), size)
        case .ratio: return place(0, output(0), size)
        case .range: return place(lowest + 6, output(lowest + 6), size)
        }
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for db in stride(from: 0.0, through: lowest, by: -12) {
            let p = place(db, db, size)
            grid.move(to: CGPoint(x: p.x, y: 0)); grid.addLine(to: CGPoint(x: p.x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: p.y)); grid.addLine(to: CGPoint(x: size.width, y: p.y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 1)
        var unity = Path()
        unity.move(to: place(lowest, lowest, size))
        unity.addLine(to: place(0, 0, size))
        context.stroke(unity, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        // Threshold line
        let t = place(threshold, threshold, size)
        var line = Path()
        line.move(to: CGPoint(x: t.x, y: 0)); line.addLine(to: CGPoint(x: t.x, y: size.height))
        context.stroke(line, with: .color(tint.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        for db in [-12.0, -24, -36, -48] where db > lowest {
            let p = place(db, db, size)
            context.draw(Text(String(format: "%.0f", db)).font(.caption2).foregroundColor(.white.opacity(0.45)),
                         at: CGPoint(x: p.x, y: size.height - 8))
        }
        context.draw(Text("IN").font(.caption2.weight(.bold)).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: size.width - 14, y: size.height - 8))
        context.draw(Text("OUT").font(.caption2.weight(.bold)).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: 18, y: 10))
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        var curve = Path()
        let steps = max(60, Int(size.width / 3))
        for i in 0...steps {
            let input = lowest + Double(i) / Double(steps) * -lowest
            let p = place(input, output(input), size)
            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
        }
        context.stroke(curve, with: .color(tint), lineWidth: 2.5)
    }

    // MARK: Dragging

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard size.width > 0, size.height > 0 else { return }
                if dragging == nil {
                    dragging = handles.min { a, b in
                        distance(position(of: a, size), drag.startLocation) < distance(position(of: b, size), drag.startLocation)
                    }
                    if let id = controlID(for: dragging) { device.touch(id, true) }
                }
                let span = -lowest
                let inputDB = lowest + Double(drag.location.x / size.width) * span
                let outputDB = lowest + Double((size.height - drag.location.y) / size.height) * span
                switch dragging {
                case .threshold?:
                    setNumber(layout.threshold, min(0, max(lowest, inputDB)))
                case .ratio?:
                    // The curve's end: how far above the threshold the loudest signal comes out.
                    let rise = outputDB - makeup - threshold
                    let newRatio = rise <= 0.3 ? .infinity : max(1, -threshold / rise)
                    setNumber(layout.ratio, newRatio)
                case .range?:
                    setNumber(layout.range, max(0, (lowest + 6) - outputDB))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if let id = controlID(for: dragging) { device.touch(id, false) }
                dragging = nil
            }
    }

    private func controlID(for handle: Handle?) -> ControlID? {
        switch handle {
        case .threshold?: return layout.threshold
        case .ratio?: return layout.ratio
        case .range?: return layout.range
        case nil: return nil
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Sets a control to a value in its own units: a parameter's position, or the nearest choice.
    private func setNumber(_ id: ControlID?, _ value: Double) {
        guard let control = control(id) else { return }
        switch control.kind {
        case .parameter(let spec):
            // Ranges may be stored as negative numbers (−40 dB) or positive (40 dB).
            let target = (layout.range == id && min(spec.min, spec.max) < 0) ? -abs(value) : value
            device.setLevel(control.id, spec.position(for: target.isInfinite ? max(spec.min, spec.max) : target))
        case .choice(let options):
            let numbers = options.map { DynamicsLayout.number(fromOption: $0) }
            func gap(_ n: Double?) -> Double {
                guard let n else { return .infinity }
                if n.isInfinite && value.isInfinite { return 0 }
                if n.isInfinite || value.isInfinite { return n.isInfinite ? max(0, 40 - value) : .infinity }
                return abs(log(n) - log(value))
            }
            if let best = numbers.indices.min(by: { gap(numbers[$0]) < gap(numbers[$1]) }) {
                if case .number(best)? = device.control(control.id).value { return }
                device.perform(control.id, .number(best))
            }
        default:
            break
        }
    }
}

/// The live signal on the curve, observed on its own so the meter can move
/// without redrawing the whole graph.
private struct MeterDot: View {
    let meter: MeterState
    let place: (MeterReading) -> CGPoint?

    var body: some View {
        if let point = place(meter.reading) {
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
                .shadow(color: .green, radius: 4)
                .position(point)
                .allowsHitTesting(false)
        }
    }
}

/// A setting as a knob: drag up or right to turn it up. The value is under it.
struct KnobView: View {
    let device: Device
    let control: ControlDescriptor
    let spec: ParameterSpec

    @Environment(\.isEnabled) private var isEnabled
    @State private var start: Double?

    private static let sweep = 270.0

    var body: some View {
        let position = device.control(control.id).value?.level ?? 0
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .trim(from: 0, to: Self.sweep / 360)
                    .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: Self.sweep / 360 * position)
                    .stroke(start != nil ? Color.yellow : Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .fill(Color(white: 0.22))
                    .padding(9)
                    .shadow(radius: start != nil ? 1 : 3, y: start != nil ? 0 : 2)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: 11)
                    .offset(y: -12)
                    .rotationEffect(.degrees(-135 + Self.sweep * position))
            }
            .frame(width: 58, height: 58)
            .scaleEffect(start != nil ? 0.95 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if start == nil {
                            start = position
                            device.touch(control.id, true)
                        }
                        let delta = Double(-drag.translation.height / 160 + drag.translation.width / 320)
                        device.setLevel(control.id, min(1, max(0, (start ?? 0) + delta)))
                    }
                    .onEnded { _ in
                        guard start != nil else { return }
                        start = nil
                        device.touch(control.id, false)
                    }
            )
            Text(control.label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(device.control(control.id).value?.level.map { spec.text(at: $0) } ?? "–")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(control.label)
        .accessibilityValue(device.control(control.id).value?.level.map { spec.text(at: $0) } ?? "unknown")
        .accessibilityAdjustableAction { direction in
            let now = device.control(control.id).value?.level ?? 0
            let step = direction == .increment ? 0.05 : -0.05
            device.perform(control.id, .level(min(1, max(0, now + step))))
        }
    }
}
