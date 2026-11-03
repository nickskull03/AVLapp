import ShowKit
import SwiftUI

struct DevicesView: View {
    @Environment(Show.self) private var show
    @AppStorage("appMode") private var mode = AppMode.both
    @State private var editing: DeviceConfig?
    @State private var adding = false

    var body: some View {
        List {
            ForEach(show.devices.filter { mode.allows($0.kind.domain) }) { device in
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
                let visible = show.devices.filter { mode.allows($0.kind.domain) }
                for i in offsets { show.removeDevice(visible[i].id) }
            }
            .onMove { source, destination in
                // Reordering is only exact when everything is shown.
                if mode == .both { show.moveDevices(from: source, to: destination) }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $mode) {
                        ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(mode.title, systemImage: mode == .both ? "rectangle.split.2x1" : mode == .lighting ? "lightbulb" : "speaker.wave.2")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if mode.allows(.audio) {
                        Section("Sound") {
                            ForEach(DeviceKind.allCases.filter { $0.domain == .audio }) { kind in
                                Button(kind.title) { editing = DeviceConfig(kind: kind) }
                            }
                        }
                    }
                    if mode.allows(.lighting) {
                        Section("Lights") {
                            ForEach(DeviceKind.allCases.filter { $0.domain == .lighting }) { kind in
                                Button(kind.title) { editing = DeviceConfig(kind: kind) }
                            }
                        }
                    }
                } label: {
                    Label("Add device", systemImage: "plus")
                }
            }
        }
        .onChange(of: mode) { _, mode in
            // Hidden devices shouldn't be controlling anything.
            for device in show.devices where !mode.allows(device.kind.domain) { device.disconnect() }
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
                        NumberField(title: config.kind == .grandMA3 ? "First column (x01–x90)" : "First playback", value: $config.firstNumber)
                    }
                    Stepper(config.kind == .grandMA3 ? "Columns \(config.count)" : "Show \(config.count)",
                            value: $config.count, in: 1...(config.kind == .chamsysMagicQ ? 10 : 90))
                    if config.kind == .grandMA3 {
                        ForEach([4, 3, 2, 1], id: \.self) { row in
                            Toggle(Self.rowTitle(row), isOn: Binding(
                                get: { config.executorRows.contains(row) },
                                set: { on in
                                    var rows = Set(config.executorRows)
                                    if on { rows.insert(row) } else { rows.remove(row) }
                                    if !rows.isEmpty { config.executorRows = rows.sorted() }
                                }
                            ))
                        }
                        Toggle("Follow the desk's page", isOn: $config.followDeskPage)
                    }
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

extension DeviceEditor {
    static func rowTitle(_ row: Int) -> String {
        switch row {
        case 1: return "Row 1xx: key under the fader"
        case 2: return "Row 2xx: fader and its key"
        default: return "Row \(row)xx: knob and key"
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
