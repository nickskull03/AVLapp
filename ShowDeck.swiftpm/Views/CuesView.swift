import ShowKit
import SwiftUI

/// Big buttons that each do several things across lights and sound.
struct CuesView: View {
    @Environment(Show.self) private var show
    @State private var editing: Cue?
    @State private var confirming: Cue?
    @State private var report: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(show.cues) { cue in
                        Button {
                            if cue.needsConfirmation { confirming = cue } else { run(cue) }
                        } label: {
                            VStack(spacing: 6) {
                                Text(cue.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                                Text("\(cue.steps.count) step\(cue.steps.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = cue }
                            Button("Delete", systemImage: "trash", role: .destructive) { show.removeCue(cue.id) }
                        }
                    }
                }
                .padding()
            }
            .overlay {
                if show.cues.isEmpty {
                    ContentUnavailableView(
                        "No cues yet",
                        systemImage: "square.grid.2x2",
                        description: Text("A cue does several things at once, like bringing up the podium light and unmuting the lectern mic. Tap + to make one.")
                    )
                }
            }
            .navigationTitle("Cues")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New cue", systemImage: "plus") { editing = Cue(name: "") }
                }
            }
            .sheet(item: $editing) { cue in
                NavigationStack {
                    CueEditor(cue: cue)
                }
            }
            .confirmationDialog(
                confirming.map { "Run \($0.name)?" } ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                Button("Run") {
                    if let confirming { run(confirming) }
                    confirming = nil
                }
            }
            .alert("Some steps didn't run", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
                Button("OK") { report = nil }
            } message: {
                Text(report ?? "")
            }
        }
    }

    private func run(_ cue: Cue) {
        let skipped = show.run(cue)
        if !skipped.isEmpty {
            report = "These devices aren't connected:\n" + skipped.map(\.summary).joined(separator: "\n")
        }
    }
}

struct CueEditor: View {
    @Environment(Show.self) private var show
    @Environment(\.dismiss) private var dismiss
    @State var cue: Cue
    @State private var addingStep = false

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Walk-in", text: $cue.name)
                Toggle("Ask before running", isOn: $cue.needsConfirmation)
            }
            Section {
                ForEach(cue.steps) { step in
                    Text(step.summary)
                }
                .onDelete { cue.steps.remove(atOffsets: $0) }
                .onMove { cue.steps.move(fromOffsets: $0, toOffset: $1) }
                Button("Add step", systemImage: "plus") { addingStep = true }
                    .disabled(show.devices.isEmpty)
            } header: {
                Text("Steps, in order")
            } footer: {
                Text("Steps can mix devices: lights and sound together.")
            }
        }
        .navigationTitle(cue.name.isEmpty ? "New cue" : cue.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    show.saveCue(cue)
                    dismiss()
                }
                .disabled(cue.name.trimmingCharacters(in: .whitespaces).isEmpty || cue.steps.isEmpty)
            }
        }
        .sheet(isPresented: $addingStep) {
            NavigationStack {
                StepPicker { cue.steps.append($0) }
            }
        }
    }
}

/// Pick a device, then a control, then what to set it to.
struct StepPicker: View {
    @Environment(Show.self) private var show
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appMode") private var mode = AppMode.both
    let onAdd: (CueStep) -> Void

    var body: some View {
        List(show.devices.filter { mode.allows($0.kind.domain) }) { device in
            NavigationLink {
                ControlPicker(device: device) { step in
                    onAdd(step)
                    dismiss()
                }
            } label: {
                Label(device.name, systemImage: device.kind.domain == .audio ? "speaker.wave.2" : "lightbulb")
            }
        }
        .navigationTitle("Device")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}

struct ControlPicker: View {
    let device: Device
    let onAdd: (CueStep) -> Void

    var body: some View {
        List {
            if !device.deviceControls.isEmpty {
                Section(device.name) {
                    ForEach(device.deviceControls.filter(\.canBeCued)) { control in
                        NavigationLink(control.label) {
                            StepValueEditor(device: device, strip: nil, control: control, onAdd: onAdd)
                        }
                    }
                }
            }
            ForEach(device.groups) { group in
                Section(group.title) {
                    ForEach(group.strips) { strip in
                        ForEach(strip.controls.filter(\.canBeCued)) { control in
                            NavigationLink("\(device.displayName(of: strip)) · \(control.label)") {
                                StepValueEditor(device: device, strip: strip, control: control, onAdd: onAdd)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Control")
    }
}

struct StepValueEditor: View {
    let device: Device
    let strip: Strip?
    let control: ControlDescriptor
    let onAdd: (CueStep) -> Void

    @State private var position = 0.0
    @State private var on = true
    @State private var number = 1
    @State private var text = ""

    var body: some View {
        Form {
            switch control.kind {
            case .fader(let unit):
                Section {
                    Slider(value: $position, in: 0...1)
                    Text(unit == .decibels ? "\(AudioTaper.text(position: position)) dB" : "\(Int((position * 100).rounded()))%")
                        .monospacedDigit()
                    if unit == .decibels {
                        Button("0 dB") { position = AudioTaper.unity }
                    }
                    Button("Use the current position") { position = device.control(control.id).value?.level ?? position }
                        .disabled(device.control(control.id).value?.level == nil)
                }
            case .toggle(let role):
                Picker(control.label, selection: $on) {
                    Text(role == .mute ? "Mute" : "On").tag(true)
                    Text(role == .mute ? "Unmute" : "Off").tag(false)
                }
                .pickerStyle(.segmented)
            case .number(let range):
                Stepper("\(control.label) \(number)", value: $number, in: range)
                    .onAppear { number = max(range.lowerBound, min(range.upperBound, number)) }
            case .command(let hint):
                TextField(hint, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .parameter(let spec):
                Section {
                    Slider(value: $position, in: 0...1)
                    Text(spec.text(at: position)).monospacedDigit()
                    Button("Use the current setting") { position = device.control(control.id).value?.level ?? position }
                        .disabled(device.control(control.id).value?.level == nil)
                }
            case .choice(let options):
                Picker(control.label, selection: $number) {
                    ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                }
                .onAppear { number = max(0, min(options.count - 1, number)) }
            case .trigger:
                Text("Fires \(control.label) when the cue runs.")
            case .momentary:
                EmptyView()
            }
            Button("Add to cue") {
                onAdd(CueStep(deviceID: device.id, control: control.id, value: value, summary: summary))
            }
        }
        .navigationTitle(control.label)
    }

    private var value: ControlValue {
        switch control.kind {
        case .fader, .parameter: return .level(position)
        case .toggle: return .on(on)
        case .number, .choice: return .number(number)
        case .command: return .text(text)
        case .trigger, .momentary: return .trigger
        }
    }

    private var summary: String {
        let target = [device.name, strip.map { device.displayName(of: $0) }, control.label].compactMap { $0 }.joined(separator: " · ")
        switch control.kind {
        case .fader(let unit):
            return "\(target) → " + (unit == .decibels ? "\(AudioTaper.text(position: position)) dB" : "\(Int((position * 100).rounded()))%")
        case .toggle(let role):
            return "\(target) → " + (role == .mute ? (on ? "muted" : "unmuted") : (on ? "on" : "off"))
        case .number: return "\(target) \(number)"
        case .parameter(let spec): return "\(target) → \(spec.text(at: position))"
        case .choice(let options): return "\(target) → \(options.indices.contains(number) ? options[number] : "\(number)")"
        case .command: return "\(target): \(text)"
        case .trigger, .momentary: return target
        }
    }
}

extension ControlDescriptor {
    /// Momentary keys need a person holding them; everything else can go in a cue.
    var canBeCued: Bool {
        if case .momentary = kind { return false }
        return true
    }
}
