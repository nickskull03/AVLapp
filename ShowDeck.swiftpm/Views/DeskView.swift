import ShowKit
import SwiftUI

/// The working surface. How many devices it shows depends on the space it
/// has, not on the kind of device, so it suits iPhone, iPad and the iPhone
/// Duo folded or open:
///
/// - **Side by side**, lights on the left and sound on the right, when it's wide
///   enough. On the Duo, opened, the split falls on the fold.
/// - **Stacked**, lights above and sound below, when it's tall rather than wide
///   (iPad in portrait).
/// - **One at a time** on phone-sized screens (iPhone, the Duo folded).
///
/// Each pane keeps its device, and each device keeps its strip group, when the
/// layout changes, so folding or rotating mid-show loses nothing.
struct DeskView: View {
    @Environment(Show.self) private var show
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
        if show.devices.isEmpty {
            ContentUnavailableView(
                "No devices yet",
                systemImage: "cable.connector",
                description: Text("Add your mixer and lighting console in Devices.")
            )
        } else {
            GeometryReader { geo in
                switch Self.arrangement(for: geo.size, deviceCount: show.devices.count) {
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

    private func pane(_ selection: Binding<String>, _ preferred: Domain) -> some View {
        DevicePane(selection: selection, preferred: preferred, groups: $groups)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One device's strips, with a menu to switch device.
struct DevicePane: View {
    @Environment(Show.self) private var show
    @Binding var selection: String
    var preferred: Domain
    @Binding var groups: [UUID: String]

    private var device: Device? {
        show.devices.first { $0.id.uuidString == selection }
            ?? show.devices.first { $0.kind.domain == preferred }
            ?? show.devices.first
    }

    var body: some View {
        if let device {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(show.devices) { other in
                        Button {
                            selection = other.id.uuidString
                        } label: {
                            Label(other.name, systemImage: other.kind.domain == .audio ? "speaker.wave.2" : "lightbulb")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(device.name).font(.headline)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                DeviceSurface(device: device, groupID: Binding(
                    get: { groups[device.id] ?? "" },
                    set: { groups[device.id] = $0 }
                ))
                .id(device.id)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)
        }
    }
}

/// A device's strip groups, its device-wide controls and its strips.
struct DeviceSurface: View {
    let device: Device
    @Binding var groupID: String

    private var group: StripGroup? {
        device.groups.first { $0.id == groupID } ?? device.groups.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if device.groups.count > 1 {
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
            if let group {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(group.strips) { strip in
                            StripView(device: device, strip: strip)
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
    }
}

struct StripView: View {
    let device: Device
    let strip: Strip

    var body: some View {
        let live = device.isLive
        VStack(spacing: 6) {
            Text(device.displayName(of: strip))
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 2)
                .background(strip.style.tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            ForEach(strip.buttons) { control in
                ControlButton(device: device, control: control, isEnabled: live)
            }
            if let fader = strip.fader {
                FaderControl(device: device, control: fader, tint: strip.style.tint, isEnabled: live)
            } else {
                Spacer()
            }
        }
        .padding(6)
        .frame(width: 78)
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

/// A strip button: a switch (lit when on), a trigger, or a key held for flash.
struct ControlButton: View {
    let device: Device
    let control: ControlDescriptor
    let isEnabled: Bool

    @State private var confirming = false
    @State private var pressed = false

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
                StripButtonLabel(title: control.label, lit: on, litColor: role == .mute ? .red : .black)
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
            StripButtonLabel(title: control.label, lit: pressed, litColor: .yellow)
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
        default:
            EmptyView()
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
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(lit ? (litColor == .yellow ? Color.black : Color.white) : Color.primary)
            .background(lit ? litColor : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Device-wide controls: scene recall, page, command line, Go.
struct DeviceControlsBar: View {
    let device: Device

    @State private var numbers: [ControlID: Int] = [:]
    @State private var command = ""
    @State private var pending: (ControlDescriptor, Int)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(device.deviceControls) { control in
                    item(control)
                }
            }
            .padding(.vertical, 2)
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
        case .command:
            TextField(control.label, text: $command)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .frame(minWidth: 220)
                .onSubmit {
                    device.perform(control.id, .text(command))
                    command = ""
                }
        case .trigger:
            Button(control.label) { device.perform(control.id, .trigger) }
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }
}
