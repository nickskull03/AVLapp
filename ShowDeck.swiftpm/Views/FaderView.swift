import ShowKit
import SwiftUI

/// A vertical touch fader. It moves relative to where the finger lands, so
/// touching it never makes it jump. Double-tap goes to `unity` when there is one.
struct FaderView: View {
    var position: Double
    var tint: Color
    var unity: Double?
    var isEnabled: Bool
    var onChange: (Double) -> Void
    var onTouch: (Bool) -> Void

    @State private var dragStart: Double?
    /// True only while the drag is alive. Unlike `onEnded`, it also resets when
    /// the system cancels the touch (a call, folding the phone), so the fader
    /// can't stay "touched" and deaf to the desk.
    @GestureState private var isDragging = false

    private let capHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.height - capHeight)
            let capY = (1 - position) * travel
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(isEnabled ? 0.85 : 0.3))
                    .frame(width: 8, height: max(0, geo.size.height - capY - capHeight / 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                if let unity {
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 26, height: 2)
                        .offset(y: (1 - unity) * travel + capHeight / 2 - 1)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: dragStart == nil ? 0.82 : 0.96))
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .frame(width: min(54, geo.size.width - 8), height: capHeight)
                    .opacity(isEnabled ? 1 : 0.5)
                    .offset(y: capY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if dragStart == nil {
                            dragStart = position
                            onTouch(true)
                        }
                        let next = min(1, max(0, (dragStart ?? position) - drag.translation.height / travel))
                        if next != position { onChange(next) }
                    }
                    .onEnded { _ in release() }
            )
            .onChange(of: isDragging) { _, dragging in
                if !dragging { release() }
            }
            // The layout can change under a finger (folding, rotating): let go.
            .onDisappear { release() }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard isEnabled, let unity else { return }
                    onTouch(true)
                    onChange(unity)
                    onTouch(false)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue("\(Int((position * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            onTouch(true)
            switch direction {
            case .increment: onChange(min(1, position + 0.05))
            case .decrement: onChange(max(0, position - 0.05))
            @unknown default: break
            }
            onTouch(false)
        }
    }
}

extension FaderView {
    private func release() {
        guard dragStart != nil else { return }
        dragStart = nil
        onTouch(false)
    }
}

struct LinkBadge: View {
    var state: LinkState
    var isSynced: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if state.isUsable && !isSynced { return "Reading desk…" }
        return state.label
    }

    private var color: Color {
        switch state {
        case .connected: return isSynced ? .green : .yellow
        case .sending: return isSynced ? .blue : .yellow
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
}

extension StripStyle {
    var tint: Color {
        switch self {
        case .input: return .teal
        case .fx: return .indigo
        case .bus: return .mint
        case .master: return .red
        case .dca: return .purple
        case .muteGroup: return .pink
        case .playback: return .orange
        case .dimmer: return .yellow
        }
    }
}
