import ShowKit
import SwiftUI

/// How the Desk splits the screen.
enum DeskLayout: String, CaseIterable, Identifiable {
    /// Two panes when there's room for them, else one.
    case auto
    case one
    case sideBySide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .one: return "One pane"
        case .sideBySide: return "Two, side by side"
        case .stacked: return "Two, one above the other"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "rectangle.3.group"
        case .one: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked: return "rectangle.split.1x2"
        }
    }
}

/// What a pane shows: a device, or the custom layer.
enum PaneSource: Equatable {
    case device(UUID)
    case layer

    static let layerTag = "layer"

    init?(tag: String) {
        if tag == Self.layerTag { self = .layer } else if let id = UUID(uuidString: tag) { self = .device(id) } else { return nil }
    }

    var tag: String {
        switch self {
        case .device(let id): return id.uuidString
        case .layer: return Self.layerTag
        }
    }
}

/// The working surface: one or two panes, each showing a device or the custom
/// layer. You choose the layout and what each pane shows; "Automatic" picks
/// one or two panes from the space there is (iPhone, iPad, the iPhone Duo
/// folded or open). Panes keep what they show when the layout changes.
struct DeskView: View {
    @Environment(Show.self) private var show
    @AppStorage("appMode") private var mode = AppMode.both
    @AppStorage("desk.layout") private var layout = DeskLayout.auto
    @AppStorage("desk.top") private var firstID = ""
    @AppStorage("desk.bottom") private var secondID = ""
    /// The strip group chosen on each device, kept here so it survives layout changes.
    @State private var groups: [UUID: String] = [:]

    enum Arrangement { case single, sideBySide, stacked }

    /// Smallest useful pane: room for a few strips across and a fader you can play.
    static func arrangement(for size: CGSize, deviceCount: Int) -> Arrangement {
        guard deviceCount > 1 else { return .single }
        let canSideBySide = size.width >= 640 && size.height >= 380
        let canStack = size.width >= 500 && size.height >= 700
        if canSideBySide && (size.width >= size.height * 0.8 || !canStack) { return .sideBySide }
        if canStack { return .stacked }
        return .single
    }

    var body: some View {
        let visible = show.devices.filter { mode.allows($0.kind.domain) }
        if visible.isEmpty {
            ContentUnavailableView(
                "No devices yet",
                systemImage: "cable.connector",
                description: Text(mode == .both ? "Add your mixer and lighting console in Devices." : "Add one in Devices, or show both halves there.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Menu {
                        Picker("Layout", selection: $layout) {
                            ForEach(DeskLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    } label: {
                        Label(layout.title, systemImage: layout.symbol)
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .accessibilityLabel("Layout: \(layout.title)")
                }
                .padding(.horizontal)
                .padding(.top, 4)
                GeometryReader { geo in
                    switch arrangement(geo.size, sources: visible.count + (show.layer.isEmpty ? 0 : 1)) {
                    case .single:
                        pane($firstID, .lighting)
                    case .sideBySide:
                        HStack(spacing: 0) {
                            pane($firstID, .lighting)
                            Divider()
                            pane($secondID, .audio)
                        }
                    case .stacked:
                        VStack(spacing: 0) {
                            pane($firstID, .lighting)
                            Divider()
                            pane($secondID, .audio)
                        }
                    }
                }
            }
        }
    }

    private func arrangement(_ size: CGSize, sources: Int) -> Arrangement {
        switch layout {
        case .auto: return Self.arrangement(for: size, deviceCount: sources)
        case .one: return .single
        case .sideBySide: return .sideBySide
        case .stacked: return .stacked
        }
    }

    private func pane(_ selection: Binding<String>, _ preferred: Domain) -> some View {
        DevicePane(selection: selection, preferred: preferred, mode: mode, groups: $groups)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One pane: a device's strips or the custom layer, with a menu to choose which.
struct DevicePane: View {
    @Environment(Show.self) private var show
    @Binding var selection: String
    var preferred: Domain
    var mode: AppMode
    @Binding var groups: [UUID: String]

    private var visible: [Device] { show.devices.filter { mode.allows($0.kind.domain) } }

    private var source: PaneSource? {
        if PaneSource(tag: selection) == .layer { return .layer }
        let device = visible.first { $0.id.uuidString == selection }
            ?? visible.first { $0.kind.domain == preferred }
            ?? visible.first
        return device.map { .device($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button {
                    selection = PaneSource.layerTag
                } label: {
                    Label("Custom layer", systemImage: "square.stack.3d.up")
                }
                Divider()
                ForEach(visible) { other in
                    Button {
                        selection = other.id.uuidString
                    } label: {
                        Label(other.name, systemImage: other.kind.domain == .audio ? "speaker.wave.2" : "lightbulb")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title).font(.headline)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            switch source {
            case .layer?:
                LayerSurface(mode: mode)
            case .device(let id)?:
                if let device = show.device(id) {
                    DeviceSurface(device: device, groupID: Binding(
                        get: { groups[device.id] ?? "" },
                        set: { groups[device.id] = $0 }
                    ))
                    .id(device.id)
                }
            case nil:
                EmptyView()
            }
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    private var title: String {
        switch source {
        case .layer?: return "Custom layer"
        case .device(let id)?: return show.device(id)?.name ?? "Device"
        case nil: return "Choose"
        }
    }
}

/// The custom layer: strips from any devices, each labelled Lights or Sound.
struct LayerSurface: View {
    @Environment(Show.self) private var show
    var mode: AppMode
    @State private var filter = AppMode.both
    @State private var detail: LayerDetail?
    @State private var editing = false

    struct LayerDetail: Identifiable {
        let device: Device
        let strip: Strip
        var id: String { "\(device.id.uuidString)/\(strip.id)" }
    }

    var body: some View {
        let strips = show.layerStrips.filter { mode.allows($0.device.kind.domain) && filter.allows($0.device.kind.domain) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if mode == .both {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(AppMode.both)
                        Text("Lights").tag(AppMode.lighting)
                        Text("Sound").tag(AppMode.audio)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Spacer()
                Button("Edit", systemImage: "pencil") { editing = true }
                    .disabled(show.layer.isEmpty)
            }
            if strips.isEmpty {
                ContentUnavailableView(
                    "Nothing on the layer yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Tap a strip's name on any device, then turn on \"On the custom layer\". Mixer channels and lighting sequences can sit side by side here.")
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(strips.map { LayerDetail(device: $0.device, strip: $0.strip) }) { entry in
                            VStack(spacing: 4) {
                                DomainTag(device: entry.device)
                                StripView(device: entry.device, strip: entry.strip) { detail = entry }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.visible)
            }
        }
        .sheet(item: $detail) { item in
            NavigationStack {
                StripDetailView(device: item.device, strip: item.strip)
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                LayerEditor()
            }
        }
    }
}

/// "LIGHTS · MA3" or "SOUND · X32" above a strip on the custom layer.
struct DomainTag: View {
    let device: Device

    var body: some View {
        let lights = device.kind.domain == .lighting
        HStack(spacing: 3) {
            Image(systemName: lights ? "lightbulb.fill" : "speaker.wave.2.fill")
            Text(lights ? "LIGHTS" : "SOUND")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(lights ? Color.orange : Color.teal, in: Capsule())
        .overlay(alignment: .bottom) {
            Text(device.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .offset(y: 14)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Reorder or remove what's on the custom layer.
struct LayerEditor: View {
    @Environment(Show.self) private var show
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(show.layer, id: \.self) { entry in
                let device = show.device(entry.deviceID)
                let strip = device?.groups.lazy.flatMap(\.strips).first { $0.id == entry.stripID }
                HStack {
                    Image(systemName: device?.kind.domain == .lighting ? "lightbulb.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(device?.kind.domain == .lighting ? Color.orange : Color.teal)
                    VStack(alignment: .leading) {
                        Text(strip.flatMap { s in device.map { $0.displayName(of: s) } } ?? entry.stripID)
                        Text(device?.name ?? "Removed device").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { show.moveLayer(from: $0, to: $1) }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) { show.removeFromLayer(show.layer[i]) }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Custom layer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// A device's strip groups, its device-wide controls and its strips.
struct DeviceSurface: View {
    let device: Device
    @Binding var groupID: String
    @State private var detail: Strip?
    /// Showing the console's keys instead of its strips.
    @State private var showingKeys = false

    private var group: StripGroup? {
        device.groups.first { $0.id == groupID } ?? device.groups.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if device.keyPanel != nil {
                    Picker("Show", selection: $showingKeys) {
                        Label("Faders", systemImage: "slider.vertical.3").tag(false)
                        Label("Keys", systemImage: "keyboard").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleOnly)
                    .fixedSize()
                }
                if device.groups.count > 1 && !(showingKeys && device.keyPanel != nil) {
                    Picker("Strips", selection: Binding(get: { group?.id ?? "" }, set: { groupID = $0 })) {
                        ForEach(device.groups) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
                Spacer(minLength: 0)
                LinkBadge(state: device.state, isSynced: device.isSynced)
                if device.isActive {
                    Button("Disconnect", systemImage: "stop.circle") { device.disconnect() }
                        .labelStyle(.iconOnly)
                } else {
                    Button("Connect") { device.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(device.config.host.isEmpty)
                }
            }
            if !device.deviceControls.isEmpty {
                DeviceControlsBar(device: device)
            }
            if showingKeys, let panel = device.keyPanel {
                KeyPanelView(device: device, panel: panel)
            } else if let group {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(group.strips) { strip in
                            StripView(device: device, strip: strip) { detail = strip }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.visible)
            }
            if device.isLive && !device.traits.reportsChanges {
                Text("This console doesn't report changes made at the desk. Faders show what this app last sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $detail) { strip in
            NavigationStack {
                StripDetailView(device: device, strip: strip)
            }
        }
    }
}

/// One strip. Top to bottom: name (tap for the detail), current cue, gain,
/// keys and knobs, fader with meters, keys under the fader.
struct StripView: View {
    let device: Device
    let strip: Strip
    let openDetail: () -> Void

    private var tint: Color {
        device.customization(strip.id).color.map(StripColor.color) ?? strip.style.tint
    }

    /// "exec.201" for a strip whose cue tools act on executor 201.
    private var cueExecutor: String? {
        guard let id = strip.sections.first(where: { $0.id == "cues" })?.controls.first?.id.rawValue else { return nil }
        return id.split(separator: ".").prefix(2).joined(separator: ".")
    }

    var body: some View {
        let live = device.isLive
        VStack(spacing: 6) {
            Button(action: openDetail) {
                VStack(spacing: 2) {
                    Text(device.displayName(of: strip))
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                    if let cueExecutor, let cue = device.info["\(cueExecutor).cue"] {
                        Text("▶ \(cue)")
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 2)
                .background(tint.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens settings for this strip")
            if let gain = strip.gain {
                ControlButton(device: device, control: gain, isEnabled: live, compact: true)
            }
            ForEach(strip.buttons) { control in
                ControlButton(device: device, control: control, isEnabled: live, compact: true)
            }
            if let fader = strip.fader {
                HStack(spacing: 4) {
                    VStack(spacing: 4) {
                        FaderControl(device: device, control: fader, tint: tint, isEnabled: live)
                    }
                    if strip.hasInputMeter || strip.hasOutputMeter {
                        MeterBars(meter: device.meterState(strip.id), input: strip.hasInputMeter, output: strip.hasOutputMeter)
                    }
                }
            } else {
                Spacer()
            }
            ForEach(strip.lowerButtons) { control in
                ControlButton(device: device, control: control, isEnabled: live, compact: true)
            }
        }
        .padding(6)
        .frame(width: strip.hasInputMeter || strip.hasOutputMeter ? 88 : 78)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FaderControl: View {
    let device: Device
    let control: ControlDescriptor
    let tint: Color
    let isEnabled: Bool

    private var unit: LevelUnit {
        if case .fader(let unit) = control.kind { return unit }
        return .percent
    }

    var body: some View {
        let state = device.control(control.id)
        let position = state.value?.level ?? 0
        FaderView(
            position: position,
            tint: tint,
            unity: unit == .decibels ? AudioTaper.unity : nil,
            isEnabled: isEnabled,
            onChange: { device.setLevel(control.id, $0) },
            onTouch: { device.touch(control.id, $0) }
        )
        Text(state.value == nil ? "–" : unit == .decibels ? AudioTaper.text(position: position) : "\(Int((position * 100).rounded()))%")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Input and output level bars beside a fader.
struct MeterBars: View {
    let meter: MeterState
    let input: Bool
    let output: Bool

    var body: some View {
        HStack(spacing: 2) {
            if input { bar(meter.reading.input) }
            if output { bar(meter.reading.output) }
        }
        .frame(width: input && output ? 10 : 5)
        .accessibilityElement()
        .accessibilityLabel("Level meter")
    }

    private func bar(_ level: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geo.size.height * (level ?? 0))
                    }
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// A control on a strip or in a list. Strips use the compact style.
struct ControlButton: View {
    let device: Device
    let control: ControlDescriptor
    let isEnabled: Bool
    var compact = false

    @State private var confirming = false
    @State private var pressed = false

    /// "exec.201" for "exec.201.key": the key's executor, for its name and running state.
    private var owner: String {
        control.id.rawValue.split(separator: ".").dropLast().joined(separator: ".")
    }

    var body: some View {
        switch control.kind {
        case .toggle(let role):
            let on = device.control(control.id).value?.isOn ?? false
            Button {
                if control.needsConfirmation && !on {
                    confirming = true
                } else {
                    device.set(control.id, on: !on)
                }
            } label: {
                StripButtonLabel(title: control.label, lit: on, litColor: role == .mute ? .red : role == .enable ? .green : .black)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .confirmationDialog("\(control.label)?", isPresented: $confirming) {
                Button(control.label, role: .destructive) { device.set(control.id, on: true) }
            }
        case .trigger:
            Button {
                if control.needsConfirmation { confirming = true } else { device.perform(control.id, .trigger) }
            } label: {
                StripButtonLabel(title: control.label, lit: false, litColor: .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .confirmationDialog("\(control.label)?", isPresented: $confirming) {
                Button(control.label) { device.perform(control.id, .trigger) }
            }
        case .momentary:
            let running = device.info["\(owner).active"] == "1"
            let name = device.info["\(owner).name"]
            StripButtonLabel(title: name.map { "\(control.label) \($0)" } ?? control.label,
                             lit: pressed || running, litColor: pressed ? .yellow : .orange)
                .opacity(isEnabled ? 1 : 0.4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard isEnabled, !pressed else { return }
                            pressed = true
                            device.perform(control.id, .press(true))
                        }
                        .onEnded { _ in
                            guard pressed else { return }
                            pressed = false
                            device.perform(control.id, .press(false))
                        }
                )
                .accessibilityAddTraits(.isButton)
        case .parameter(let spec):
            ParameterSlider(device: device, control: control, spec: spec, isEnabled: isEnabled, compact: compact)
        default:
            EmptyView()
        }
    }
}

/// A setting as a slider with its value: gain on a strip, EQ in a detail.
struct ParameterSlider: View {
    let device: Device
    let control: ControlDescriptor
    let spec: ParameterSpec
    let isEnabled: Bool
    var compact = false

    var body: some View {
        let position = device.control(control.id).value?.level
        VStack(spacing: compact ? 0 : 4) {
            HStack {
                Text(control.label)
                Spacer(minLength: 4)
                Text(position.map { spec.text(at: $0) } ?? "–").monospacedDigit()
            }
            .font(compact ? .caption2 : .body)
            .foregroundStyle(compact ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Slider(
                value: Binding(get: { position ?? spec.position(for: spec.min) }, set: { device.setLevel(control.id, $0) }),
                in: 0...1,
                onEditingChanged: { device.touch(control.id, $0) }
            )
            .controlSize(compact ? .mini : .regular)
            .disabled(!isEnabled)
        }
    }
}

struct StripButtonLabel: View {
    var title: String
    var lit: Bool
    var litColor: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(lit ? (litColor == .yellow ? Color.black : Color.white) : Color.primary)
            .background(lit ? litColor : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Device-wide controls: scene recall, page, Go, and a sheet for typed commands.
struct DeviceControlsBar: View {
    let device: Device

    @State private var numbers: [ControlID: Int] = [:]
    @State private var pending: (ControlDescriptor, Int)?
    @State private var showingCommands = false

    private var commands: [ControlDescriptor] {
        device.deviceControls.filter { if case .command = $0.kind { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(device.deviceControls) { control in
                        item(control)
                    }
                    if !commands.isEmpty {
                        Button("Commands", systemImage: "command") { showingCommands = true }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 2)
            }
            if let message = device.info["device.message"] {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if device.info["device.cue.active"] != nil || device.info["device.cue.pending"] != nil {
                HStack(spacing: 12) {
                    if let active = device.info["device.cue.active"] { Label(active, systemImage: "play.fill") }
                    if let pending = device.info["device.cue.pending"] { Label(pending, systemImage: "forward.end") }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .disabled(!device.isLive)
        .confirmationDialog(
            pending.map { "\($0.0.label) \($0.1)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button(pending?.0.label ?? "Go") {
                if case let (control, number)? = pending { device.perform(control.id, .number(number)) }
                pending = nil
            }
        }
        .sheet(isPresented: $showingCommands) {
            NavigationStack {
                Form {
                    Section {
                        ForEach(commands) { control in
                            ControlRow(device: device, control: control)
                        }
                    }
                }
                .navigationTitle(device.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showingCommands = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func item(_ control: ControlDescriptor) -> some View {
        switch control.kind {
        case .number(let range):
            let value = numbers[control.id] ?? range.lowerBound
            HStack(spacing: 6) {
                Stepper(value: Binding(get: { value }, set: { numbers[control.id] = $0 }), in: range) {
                    Text("\(control.label) \(value)").font(.subheadline.monospacedDigit())
                }
                .fixedSize()
                Button(control.needsConfirmation ? "Go" : "Set") {
                    if control.needsConfirmation {
                        pending = (control, value)
                    } else {
                        device.perform(control.id, .number(value))
                    }
                }
                .buttonStyle(.bordered)
            }
        case .trigger:
            Button(control.label) { device.perform(control.id, .trigger) }
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }
}
