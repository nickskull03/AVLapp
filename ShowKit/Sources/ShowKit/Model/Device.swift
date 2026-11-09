import Foundation
import Observation

/// A control's live value, observed separately per control so moving one
/// fader only redraws that fader.
@MainActor
@Observable
public final class ControlState {
    /// nil until the console has reported it (or we've set it).
    public internal(set) var value: ControlValue?
    /// A finger is on it: the console's reports are ignored meanwhile.
    public internal(set) var isTouched = false

    init() {}
}

@MainActor
@Observable
public final class StripState {
    /// The name from the console, if it reports names.
    public internal(set) var name: String?

    init() {}
}

/// A strip's signal levels, observed on their own so meters redraw without
/// redrawing anything else.
@MainActor
@Observable
public final class MeterState {
    public internal(set) var reading = MeterReading()

    init() {}
}

/// One console as the app sees it. Sits between the UI and a driver and
/// takes care of the things every console needs:
///
/// - controls stay locked until the console's state has been read, and the
///   app never pushes stored values on connect (the desk is the source of truth);
/// - while a finger is on a fader, the console's reports for it are ignored,
///   and just after we send, its echoes are too;
/// - fader moves go out at most ~30 times a second, and the final value always goes;
/// - switches are sent as explicit states, never toggles;
/// - a dropped connection is retried with backoff, and re-read when it returns.
@MainActor
@Observable
public final class Device: Identifiable {
    public nonisolated let id: UUID
    public private(set) var config: DeviceConfig
    public private(set) var state: LinkState = .disconnected
    /// The console's state has been read (or it can't be: see `traits`).
    public private(set) var isSynced = false
    public private(set) var groups: [StripGroup] = []
    public private(set) var deviceControls: [ControlDescriptor] = []
    public private(set) var traits = DriverTraits(reportsChanges: false, readsNames: false)
    /// The console's keys, when it takes them.
    public private(set) var keyPanel: KeyPanel?
    /// The user wants this device connected.
    public private(set) var isActive = false
    /// What the console reports besides values: current cues, running states.
    /// Keys as in `DriverSink.info`.
    public private(set) var info: [String: String] = [:]

    /// Send at most this often per control while dragging.
    static let sendInterval: Duration = .milliseconds(33)
    /// Ignore the console's reports this long after we send, so old echoes
    /// don't pull the fader back.
    static let echoWindow: Duration = .milliseconds(400)
    /// If reading the state takes longer than this, unlock anyway.
    static let syncTimeout: Double = 6

    private let makeTransport: TransportFactory
    @ObservationIgnored private var driver: ConsoleDriver?
    @ObservationIgnored private var controls: [ControlID: ControlState] = [:]
    @ObservationIgnored private var strips: [String: StripState] = [:]
    @ObservationIgnored private var meters: [String: MeterState] = [:]
    @ObservationIgnored private var outgoing: [ControlID: Outgoing] = [:]
    private let retry = Ticker()
    private let syncWatchdog = Ticker()
    @ObservationIgnored private var retryDelay = 1.0
    @ObservationIgnored private var isSuspended = false

    private struct Outgoing {
        var lastSent: ContinuousClock.Instant?
        var queued: ControlValue?
        var flushTask: Task<Void, Never>?
    }

    public init(config: DeviceConfig, transport: @escaping TransportFactory) {
        id = config.id
        self.config = config
        makeTransport = transport
        rebuildDriver()
    }

    public var kind: DeviceKind { config.kind }
    public var name: String { config.name }

    /// Controls are usable: connected, and the console's state is known.
    public var isLive: Bool { state.isUsable && isSynced }

    // MARK: Connection

    public func connect() {
        isActive = true
        isSuspended = false
        retryDelay = 1
        restart()
    }

    public func disconnect() {
        isActive = false
        retry.stop()
        syncWatchdog.stop()
        driver?.stop()
        isSynced = false
        state = .disconnected
    }

    /// Drop the connection but remember it's wanted (the app went to the background).
    public func suspend() {
        guard isActive else { return }
        isSuspended = true
        retry.stop()
        syncWatchdog.stop()
        driver?.stop()
        isSynced = false
        state = .disconnected
    }

    /// Reconnect if it's wanted, and read the console's state again.
    public func resume() {
        guard isActive, isSuspended else { return }
        isSuspended = false
        retryDelay = 1
        restart()
    }

    public func update(_ newConfig: DeviceConfig) {
        guard newConfig != config else { return }
        if newConfig.sameConnection(as: config) {
            // Only names, colours or button actions: no need to reconnect.
            config = newConfig
            driver?.apply(customizations: newConfig.customizations)
            return
        }
        config = newConfig
        let wasActive = isActive
        driver?.stop()
        rebuildDriver()
        if wasActive { restart() }
    }

    // MARK: Controls

    public func control(_ id: ControlID) -> ControlState {
        if let existing = controls[id] { return existing }
        let created = ControlState()
        controls[id] = created
        return created
    }

    public func stripState(_ stripID: String) -> StripState {
        if let existing = strips[stripID] { return existing }
        let created = StripState()
        strips[stripID] = created
        return created
    }

    public func meterState(_ stripID: String) -> MeterState {
        if let existing = meters[stripID] { return existing }
        let created = MeterState()
        meters[stripID] = created
        return created
    }

    /// The user's name for the strip, else the console's, else the default.
    public func displayName(of strip: Strip) -> String {
        if let custom = config.customizations[strip.id]?.name, !custom.isEmpty { return custom }
        return stripState(strip.id).name ?? strip.defaultName
    }

    public func customization(_ stripID: String) -> StripCustomization {
        config.customizations[stripID] ?? StripCustomization()
    }

    /// The user opened a strip's detail: ask the console for its processing.
    public func openDetail(_ stripID: String) {
        driver?.detailOpened(stripID)
    }

    /// A fader move from a finger: throttled, final value guaranteed by `touch(_:false)`.
    public func setLevel(_ id: ControlID, _ position: Double) {
        let value = ControlValue.level(clamp01(position))
        control(id).value = value
        sendThrottled(id, value)
    }

    /// A finger landed on or left a control.
    public func touch(_ id: ControlID, _ touching: Bool) {
        control(id).isTouched = touching
        if !touching { flush(id) }
    }

    /// Lets go of every control a finger was on, and sends their final values.
    /// For when touches can't end normally: the app is interrupted, or the
    /// screen it was on changes shape.
    public func releaseTouches() {
        for (id, state) in controls where state.isTouched {
            touch(id, false)
        }
    }

    /// Sets a switch to an explicit state.
    public func set(_ id: ControlID, on: Bool) {
        perform(id, .on(on))
    }

    /// Sends a value right away: switches, triggers, presses, numbers, commands,
    /// and fader values from cues.
    public func perform(_ id: ControlID, _ value: ControlValue) {
        guard let driver else { return }
        switch value {
        case .level, .on:
            control(id).value = value
            cancelQueued(id)
            outgoing[id, default: Outgoing()].lastSent = .now
        default:
            break
        }
        driver.send(id, value)
    }

    // MARK: Private

    private func rebuildDriver() {
        let driver = Drivers.make(config, transport: makeTransport)
        driver.sink.state = { [weak self] in self?.driverState($0) }
        driver.sink.value = { [weak self] in self?.received($0, $1) }
        driver.sink.name = { [weak self] stripID, name in self?.stripState(stripID).name = name.isEmpty ? nil : name }
        driver.sink.synced = { [weak self] in self?.markSynced() }
        driver.sink.meters = { [weak self] readings in
            guard let self else { return }
            // Merge: a report may carry only inputs or only outputs.
            for (stripID, reading) in readings {
                let state = self.meterState(stripID)
                var merged = state.reading
                if let input = reading.input { merged.input = input }
                if let output = reading.output { merged.output = output }
                if merged != state.reading { state.reading = merged }
            }
        }
        driver.sink.info = { [weak self] key, text in
            guard let self, self.info[key] != text else { return }
            self.info[key] = text
        }
        driver.sink.layoutChanged = { [weak self, weak driver] in
            guard let self, let driver, driver === self.driver else { return }
            self.groups = driver.groups
            self.deviceControls = driver.deviceControls
            self.keyPanel = driver.keyPanel
        }
        driver.apply(customizations: config.customizations)
        self.driver = driver
        groups = driver.groups
        deviceControls = driver.deviceControls
        traits = driver.traits
        keyPanel = driver.keyPanel
        info = [:]
        controls.removeAll()
        strips.removeAll()
        meters.removeAll()
        outgoing.values.forEach { $0.flushTask?.cancel() }
        outgoing.removeAll()
        isSynced = false
        state = .disconnected
    }

    private func restart() {
        retry.stop()
        driver?.stop()
        isSynced = false
        state = .connecting
        driver?.start()
    }

    private func driverState(_ newState: LinkState) {
        guard isActive else { return }
        state = newState
        switch newState {
        case .connected, .sending:
            retryDelay = 1
            if !isSynced {
                syncWatchdog.once(after: Self.syncTimeout) { [weak self] in self?.markSynced() }
            }
        case .failed:
            isSynced = false
            syncWatchdog.stop()
            driver?.stop()
            state = newState // stop() may have reported .disconnected
            let delay = retryDelay
            retryDelay = min(10, retryDelay * 2)
            retry.once(after: delay) { [weak self] in
                guard let self, self.isActive else { return }
                self.restart()
            }
        case .disconnected, .connecting:
            break
        }
    }

    private func markSynced() {
        syncWatchdog.stop()
        isSynced = true
    }

    private func received(_ id: ControlID, _ value: ControlValue) {
        let state = control(id)
        if state.isTouched { return }
        if let out = outgoing[id] {
            if out.queued != nil { return }
            if let last = out.lastSent, ContinuousClock.now - last < Self.echoWindow { return }
        }
        state.value = value
    }

    private func sendThrottled(_ id: ControlID, _ value: ControlValue) {
        var out = outgoing[id] ?? Outgoing()
        let now = ContinuousClock.now
        if let last = out.lastSent, now - last < Self.sendInterval {
            out.queued = value
            if out.flushTask == nil {
                let wait = Self.sendInterval - (now - last)
                out.flushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.flush(id)
                }
            }
            outgoing[id] = out
        } else {
            out.lastSent = now
            out.queued = nil
            outgoing[id] = out
            driver?.send(id, value)
        }
    }

    private func flush(_ id: ControlID) {
        guard var out = outgoing[id] else { return }
        out.flushTask?.cancel()
        out.flushTask = nil
        if let value = out.queued {
            out.queued = nil
            out.lastSent = .now
            driver?.send(id, value)
        }
        outgoing[id] = out
    }

    private func cancelQueued(_ id: ControlID) {
        outgoing[id]?.flushTask?.cancel()
        outgoing[id]?.flushTask = nil
        outgoing[id]?.queued = nil
    }
}
