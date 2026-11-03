import ShowKit
import SwiftUI

/// What the app shows: both halves, or just one.
enum AppMode: String, CaseIterable, Identifiable {
    case both, lighting, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Lights & Sound"
        case .lighting: return "Lights only"
        case .audio: return "Sound only"
        }
    }

    func allows(_ domain: Domain) -> Bool {
        switch self {
        case .both: return true
        case .lighting: return domain == .lighting
        case .audio: return domain == .audio
        }
    }
}

enum StripColor {
    static func color(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .gray
        }
    }
}

/// A strip's settings: its name and colour, what its buttons do, and its
/// processing (EQ, dynamics) or cue tools.
struct StripDetailView: View {
    @Environment(Show.self) private var show
    @Environment(\.dismiss) private var dismiss
    let device: Device
    let strip: Strip

    private var custom: StripCustomization { device.customization(strip.id) }

    private var momentaryControls: [ControlDescriptor] {
        (strip.buttons + strip.lowerButtons).filter { if case .momentary = $0.kind { return true } else { return false } }
    }

    var body: some View {
        Form {
            Section("Name and colour") {
                TextField(strip.defaultName, text: Binding(
                    get: { custom.name ?? "" },
                    set: { name in save { $0.name = name.isEmpty ? nil : name } }
                ))
                .autocorrectionDisabled()
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        colourButton(nil)
                        ForEach(StripCustomization.colors, id: \.self) { colourButton($0) }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !device.traits.buttonActions.isEmpty && !momentaryControls.isEmpty {
                Section {
                    ForEach(momentaryControls) { control in
                        Picker(buttonTitle(control), selection: Binding(
                            get: { custom.actions[control.id.rawValue] ?? "key" },
                            set: { action in save { $0.actions[control.id.rawValue] = action == "key" ? nil : action } }
                        )) {
                            ForEach(device.traits.buttonActions) { Text($0.label).tag($0.id) }
                        }
                    }
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("\"As set on the desk\" presses the executor's own key, so it does whatever that key does on the console.")
                }
            }

            ForEach(strip.sections) { section in
                Section {
                    ForEach(section.controls) { control in
                        ControlRow(device: device, control: control)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let note = section.note { Text(note) }
                }
            }

            if let note = device.traits.note {
                Section {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(device.displayName(of: strip))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { device.openDetail(strip.id) }
    }

    private func buttonTitle(_ control: ControlDescriptor) -> String {
        let owner = control.id.rawValue.split(separator: ".").dropLast().joined(separator: ".")
        if let name = device.info["\(owner).name"] { return "\(control.label) \(name)" }
        return "Key \(control.label)"
    }

    private func colourButton(_ name: String?) -> some View {
        let selected = custom.color == name
        return Button {
            save { $0.color = name }
        } label: {
            Circle()
                .fill(name.map(StripColor.color) ?? strip.style.tint)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 3 : 0))
                .overlay {
                    if name == nil { Image(systemName: "arrow.uturn.backward").font(.caption).foregroundStyle(.white) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? "Default colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ change: (inout StripCustomization) -> Void) {
        var config = device.config
        var custom = config.customizations[strip.id] ?? StripCustomization()
        change(&custom)
        config.customizations[strip.id] = custom.isEmpty ? nil : custom
        show.updateDevice(config)
    }
}

/// One control in a list: a slider, switch, picker, command field or button.
struct ControlRow: View {
    let device: Device
    let control: ControlDescriptor

    @State private var text = ""
    @State private var confirming = false
    @State private var number = 0

    var body: some View {
        let live = device.isLive
        Group {
            switch control.kind {
            case .parameter(let spec):
                ParameterSlider(device: device, control: control, spec: spec, isEnabled: live)
            case .fader:
                ParameterSlider(device: device, control: control, spec: ParameterSpec(0, 100, unit: "%", decimals: 0), isEnabled: live)
            case .toggle:
                Toggle(control.label, isOn: Binding(
                    get: { device.control(control.id).value?.isOn ?? false },
                    set: { device.set(control.id, on: $0) }
                ))
            case .choice(let options):
                let current = choiceIndex
                Picker(control.label, selection: Binding<Int?>(
                    get: { current },
                    set: { if let i = $0 { device.perform(control.id, .number(i)) } }
                )) {
                    if current == nil { Text("–").tag(Int?.none) }
                    ForEach(options.indices, id: \.self) { Text(options[$0]).tag(Int?.some($0)) }
                }
            case .command(let hint):
                VStack(alignment: .leading, spacing: 6) {
                    Text(control.label)
                    HStack {
                        TextField(hint, text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .submitLabel(.send)
                            .onSubmit(sendText)
                        Button("Send", action: sendText)
                            .buttonStyle(.bordered)
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            case .trigger:
                Button(control.label) {
                    if control.needsConfirmation { confirming = true } else { device.perform(control.id, .trigger) }
                }
            case .number(let range):
                HStack {
                    Stepper("\(control.label) \(number)", value: $number, in: range)
                    Button("Go") {
                        if control.needsConfirmation { confirming = true } else { device.perform(control.id, .number(number)) }
                    }
                    .buttonStyle(.bordered)
                }
                .onAppear { number = max(range.lowerBound, min(range.upperBound, number)) }
            case .momentary:
                Text(control.label).foregroundStyle(.secondary)
            }
        }
        .disabled(!live)
        .confirmationDialog("\(control.label)?", isPresented: $confirming, titleVisibility: .visible) {
            Button(control.label) { confirmed() }
        } message: {
            if case .command = control.kind { Text(text) }
        }
    }

    private var choiceIndex: Int? {
        if case .number(let i)? = device.control(control.id).value { return i }
        return nil
    }

    private func sendText() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if control.needsConfirmation {
            confirming = true
        } else {
            device.perform(control.id, .text(text))
            text = ""
        }
    }

    private func confirmed() {
        switch control.kind {
        case .command:
            device.perform(control.id, .text(text))
            text = ""
        case .number:
            device.perform(control.id, .number(number))
        default:
            device.perform(control.id, .trigger)
        }
    }
}
