import Foundation
import Observation

/// One thing a cue does: set a control on a device.
public struct CueStep: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var deviceID: UUID
    public var control: ControlID
    public var value: ControlValue
    /// What the step was described as when made, e.g. "X32 · Vox 1 · Mute on",
    /// so it still reads sensibly if the device is gone.
    public var summary: String

    public init(deviceID: UUID, control: ControlID, value: ControlValue, summary: String) {
        id = UUID()
        self.deviceID = deviceID
        self.control = control
        self.value = value
        self.summary = summary
    }
}

/// A button that does several things at once across lights and sound, like
/// "Walk-in" (house look, playback music up) or "Speech" (podium special, lectern mic on).
public struct Cue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [CueStep]
    public var needsConfirmation: Bool

    public init(name: String, steps: [CueStep] = [], needsConfirmation: Bool = false) {
        id = UUID()
        self.name = name
        self.steps = steps
        self.needsConfirmation = needsConfirmation
    }
}

/// A strip on the custom layer: which device, which strip.
public struct LayerEntry: Codable, Hashable, Sendable {
    public var deviceID: UUID
    public var stripID: String

    public init(deviceID: UUID, stripID: String) {
        self.deviceID = deviceID
        self.stripID = stripID
    }
}

/// The whole setup: devices, cues and the custom layer. Saved as JSON whenever it changes.
@MainActor
@Observable
public final class Show {
    public private(set) var devices: [Device] = []
    public private(set) var cues: [Cue] = []
    /// The custom layer: strips from any devices, lights and sound, in the user's order.
    public private(set) var layer: [LayerEntry] = []

    private let fileURL: URL?
    private let makeTransport: TransportFactory

    private struct Stored: Codable {
        var version = 1
        var devices: [DeviceConfig]
        var cues: [Cue]
        var layer: [LayerEntry]

        init(devices: [DeviceConfig], cues: [Cue], layer: [LayerEntry]) {
            self.devices = devices
            self.cues = cues
            self.layer = layer
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            devices = try c.decodeIfPresent([DeviceConfig].self, forKey: .devices) ?? []
            cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
            layer = try c.decodeIfPresent([LayerEntry].self, forKey: .layer) ?? []
        }
    }

    /// `fileURL` nil keeps everything in memory (tests, previews).
    public init(fileURL: URL?, transport: @escaping TransportFactory) {
        self.fileURL = fileURL
        makeTransport = transport
        load()
    }

    public static var defaultFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("show.json")
    }

    public func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    // MARK: Devices

    @discardableResult
    public func addDevice(_ config: DeviceConfig) -> Device {
        let device = Device(config: config, transport: makeTransport)
        devices.append(device)
        save()
        return device
    }

    public func updateDevice(_ config: DeviceConfig) {
        device(config.id)?.update(config)
        save()
    }

    public func removeDevice(_ id: UUID) {
        device(id)?.disconnect()
        devices.removeAll { $0.id == id }
        layer.removeAll { $0.deviceID == id }
        save()
    }

    public func moveDevices(from source: IndexSet, to destination: Int) {
        devices.moveItems(from: source, to: destination)
        save()
    }

    /// Connects every device marked to connect automatically.
    public func connectAutomatically(where include: (DeviceConfig) -> Bool = { _ in true }) {
        for device in devices where device.config.autoConnect && !device.config.host.isEmpty && include(device.config) {
            device.connect()
        }
    }

    /// The app went to the background: iOS will drop the sockets anyway.
    public func suspend() {
        devices.forEach { $0.suspend() }
    }

    /// A call, Control Centre or a fold interrupted touches: let them all go.
    public func releaseTouches() {
        devices.forEach { $0.releaseTouches() }
    }

    /// Back in the foreground: reconnect and re-read every console.
    public func resume() {
        devices.forEach { $0.resume() }
    }

    // MARK: Custom layer

    public func isInLayer(_ entry: LayerEntry) -> Bool {
        layer.contains(entry)
    }

    public func addToLayer(_ entry: LayerEntry) {
        guard !layer.contains(entry) else { return }
        layer.append(entry)
        save()
    }

    public func removeFromLayer(_ entry: LayerEntry) {
        layer.removeAll { $0 == entry }
        save()
    }

    public func moveLayer(from source: IndexSet, to destination: Int) {
        layer.moveItems(from: source, to: destination)
        save()
    }

    /// The layer's strips that can be shown: their device exists and has that strip.
    public var layerStrips: [(device: Device, strip: Strip)] {
        layer.compactMap { entry in
            guard let device = device(entry.deviceID),
                  let strip = device.groups.lazy.flatMap(\.strips).first(where: { $0.id == entry.stripID }) else { return nil }
            return (device: device, strip: strip)
        }
    }

    // MARK: Cues

    public func saveCue(_ cue: Cue) {
        if let i = cues.firstIndex(where: { $0.id == cue.id }) {
            cues[i] = cue
        } else {
            cues.append(cue)
        }
        save()
    }

    public func removeCue(_ id: UUID) {
        cues.removeAll { $0.id == id }
        save()
    }

    public func moveCues(from source: IndexSet, to destination: Int) {
        cues.moveItems(from: source, to: destination)
        save()
    }

    /// Runs every step. Returns the steps that couldn't run (device missing or offline).
    @discardableResult
    public func run(_ cue: Cue) -> [CueStep] {
        var skipped: [CueStep] = []
        for step in cue.steps {
            guard let device = device(step.deviceID), device.isLive else {
                skipped.append(step)
                continue
            }
            device.perform(step.control, step.value)
        }
        return skipped
    }

    // MARK: Storage

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        devices = stored.devices.map { Device(config: $0, transport: makeTransport) }
        cues = stored.cues
        layer = stored.layer
    }

    private func save() {
        guard let fileURL else { return }
        let stored = Stored(devices: devices.map(\.config), cues: cues, layer: layer)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension Array {
    /// Moves the items at `source` so they land before the item now at
    /// `destination`, the way list reordering reports it.
    mutating func moveItems(from source: IndexSet, to destination: Int) {
        let moving = source.map { self[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { remove(at: i) }
        insert(contentsOf: moving, at: Swift.min(count, Swift.max(0, destination - before)))
    }
}
