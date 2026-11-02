import ShowKit
import SwiftUI

struct DevicesView: View {
    @Environment(Show.self) private var show
    @State private var editing: DeviceConfig?
    @State private var adding = false

    var body: some View {
        List {
            ForEach(show.devices) { device in
                HStack {
                    Image(systemName: device.kind.domain == .audio ? "speaker.wave.2" : "lightbulb")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.headline)
                        Text("\(device.kind.title) · \(device.config.host.isEmpty ? "no IP set" : device.config.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LinkBadge(state: device.state, isSynced: device.isSynced)
                    Toggle("Connected", isOn: Binding(
                        get: { device.isActive },
                        set: { $0 ? device.connect() : device.disconnect() }
                    ))
                    .labelsHidden()
                    .disabled(device.config.host.isEmpty)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = device.config }
            }
            .onDelete { offsets in
                for i in offsets { show.removeDevice(show.devices[i].id) }
            }
            .onMove { show.moveDevices(from: $0, to: $1) }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Sound") {
                        ForEach(DeviceKind.allCases.filter { $0.domain == .audio }) { kind in
                            Button(kind.title) { editing = DeviceConfig(kind: kind) }
                        }
                    }
                    Section("Lights") {
                        ForEach(DeviceKind.allCases.filter { $0.domain == .lighting }) { kind in
                            Button(kind.title) { editing = DeviceConfig(kind: kind) }
                        }
                    }
                } label: {
                    Label("Add device", systemImage: "plus")
                }
            }
        }
        .overlay {
            if show.devices.isEmpty {
                ContentUnavailableView(
                    "Add your consoles",
                    systemImage: "plus.circle",
                    description: Text("Tap + to add a mixer or lighting console. Each one comes with the steps to set it up.")
                )
            }
        }
        .sheet(item: $editing) { config in
            NavigationStack {
                DeviceEditor(config: config, isNew: show.device(config.id) == nil)
            }
        }
    }
}

struct DeviceEditor: View {
    @Environment(Show.self) private var show
    @Environment(\.dismiss) private var dismiss
    @State var config: DeviceConfig
    let isNew: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $config.name)
                LabeledContent("IP address") {
                    TextField("192.168.1.10", text: $config.host)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !config.kind.variants.isEmpty {
                    Picker("Model", selection: $config.variant) {
                        ForEach(config.kind.variants) { Text($0.title).tag($0.id) }
                    }
                    .onChange(of: config.variant) { _, variant in
                        if config.kind == .allenHeathDLive { config.port = variant == "surface" ? 51328 : 51325 }
                    }
                }
                NumberField(title: "Port", value: $config.port)
                if config.kind.usesMIDIChannel {
                    Stepper("MIDI channel \(config.midiChannel)", value: $config.midiChannel,
                            in: 1...(config.kind == .allenHeathDLive ? 12 : 16))
                }
                Toggle("Connect when the app opens", isOn: $config.autoConnect)
            } header: {
                Text(config.kind.title)
            }

            if config.kind == .grandMA3 || config.kind == .chamsysMagicQ {
                Section {
                    NumberField(title: "Feedback port (0 = none)", value: $config.feedbackPort)
                    if config.kind == .grandMA3 {
                        LabeledContent("OSC prefix") {
                            TextField("gma3", text: $config.oscPrefix)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        LabeledContent("Fader range") {
                            TextField("100", value: $config.faderRange, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                        }
                        NumberField(title: "Page", value: $config.page)
                    }
                } header: {
                    Text("OSC")
                }
            }
            if config.kind.usesPlaybackRange {
                Section("Faders") {
                    if config.kind != .etcEos {
                        NumberField(title: config.kind == .grandMA3 ? "First executor" : "First playback", value: $config.firstNumber)
                    }
                    Stepper("Show \(config.count)", value: $config.count, in: 1...(config.kind == .chamsysMagicQ ? 10 : 90))
                    if config.kind == .etcEos {
                        Stepper("OSC user \(config.user)", value: $config.user, in: 0...99)
                    }
                }
            }
            if config.kind == .artNet {
                Section("DMX") {
                    NumberField(title: "Universe", value: $config.universe)
                    NumberField(title: "First channel", value: $config.firstNumber)
                    Stepper("Channels \(config.count)", value: $config.count, in: 1...512)
                }
            }

            Section("Set up the console") {
                ForEach(Array(config.kind.setupSteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(step)
                    }
                    .font(.callout)
                }
            }

            if !isNew {
                Section {
                    Button("Remove device", role: .destructive) {
                        show.removeDevice(config.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add device" : config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    if isNew {
                        let device = show.addDevice(config)
                        if config.autoConnect && !config.host.isEmpty { device.connect() }
                    } else {
                        show.updateDevice(config)
                    }
                    dismiss()
                }
                .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct NumberField: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
        }
    }
}
