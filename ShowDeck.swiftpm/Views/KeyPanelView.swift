import ShowKit
import SwiftUI

/// A console's keys: its command line at the top, then sections of keys
/// (objects, functions, the number pad, playback) side by side where there's
/// room and one under the other where there isn't.
struct KeyPanelView: View {
    let device: Device
    let panel: KeyPanel

    /// The command line being built, for consoles that take whole lines.
    @State private var line = ""
    @State private var confirming: PanelKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            commandLine
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(panel.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                                ForEach(section.rows.indices, id: \.self) { r in
                                    GridRow {
                                        ForEach(section.rows[r]) { key in
                                            keyView(key)
                                                .gridCellColumns(key.span)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .disabled(!device.isLive)
        .opacity(device.isLive ? 1 : 0.5)
        .confirmationDialog(
            confirming.map { "\($0.label)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirming?.label ?? "OK") {
                if let key = confirming, case .trigger(let id) = key.action { device.perform(id, .trigger) }
                confirming = nil
            }
        }
    }

    // MARK: Command line

    @ViewBuilder
    private var commandLine: some View {
        switch panel.commandLine {
        case .none:
            EmptyView()
        case .local:
            lineView(line.isEmpty ? "Type a command with the keys" : line, placeholder: line.isEmpty)
        case .console(let infoKey):
            let text = device.info[infoKey] ?? ""
            lineView(text.isEmpty ? "The console's command line shows here" : text, placeholder: text.isEmpty)
        }
    }

    private func lineView(_ text: String, placeholder: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(placeholder ? Color.white.opacity(0.4) : Color.green)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command line")
        .accessibilityValue(placeholder ? "Empty" : text)
    }

    // MARK: Keys

    @ViewBuilder
    private func keyView(_ key: PanelKey) -> some View {
        switch key.action {
        case .label:
            Text(key.label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
        case .press(let id):
            PressKey(device: device, key: key, id: id)
        default:
            Button {
                tapped(key)
            } label: {
                KeyCap(key: key, pressed: false)
            }
            .buttonStyle(KeyPressStyle())
        }
    }

    private func tapped(_ key: PanelKey) {
        switch key.action {
        case .type(let text):
            line = KeyPanel.append(text, to: line)
        case .backspace:
            line = KeyPanel.deleteLast(line)
        case .clear(let fallback):
            if !line.isEmpty {
                line = ""
            } else if let fallback {
                device.perform(fallback, .trigger)
            }
        case .enter:
            guard case .local(let target) = panel.commandLine else { return }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            device.perform(target, .text(text))
            line = ""
        case .trigger(let id):
            if key.needsConfirmation { confirming = key } else { device.perform(id, .trigger) }
        case .press, .label:
            break
        }
    }
}

/// A key held on the console for as long as the finger is on it.
private struct PressKey: View {
    let device: Device
    let key: PanelKey
    let id: ControlID

    @Environment(\.isEnabled) private var isEnabled
    @State private var pressed = false

    var body: some View {
        KeyCap(key: key, pressed: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !pressed else { return }
                        pressed = true
                        device.perform(id, .press(true))
                    }
                    .onEnded { _ in release() }
            )
            .onDisappear(perform: release)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(key.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                device.perform(id, .press(true))
                device.perform(id, .press(false))
            }
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        device.perform(id, .press(false))
    }
}

/// How a key looks: coloured by what it's for, lit while pressed.
struct KeyCap: View {
    let key: PanelKey
    let pressed: Bool

    var body: some View {
        Text(key.label)
            .font(key.role == .number ? .title3.weight(.semibold).monospacedDigit() : .subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(pressed ? Color.black : foreground)
            .background(pressed ? Color.yellow : background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var background: Color {
        switch key.role {
        case .normal: return Color.primary.opacity(0.1)
        case .keyword: return Color.blue.opacity(0.25)
        case .number: return Color.primary.opacity(0.16)
        case .go: return Color.green.opacity(0.8)
        case .stop: return Color.orange.opacity(0.8)
        case .enter: return Color.accentColor
        case .clear: return Color.red.opacity(0.25)
        }
    }

    private var foreground: Color {
        switch key.role {
        case .go, .stop, .enter: return .white
        default: return .primary
        }
    }
}

/// Lights a tapped key while the finger is down.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.15 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
