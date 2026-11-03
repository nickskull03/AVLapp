import Foundation

/// Where a driver reports what it hears. `Device` fills these in.
@MainActor
public final class DriverSink {
    public var state: (LinkState) -> Void = { _ in }
    /// A control's value as the console reports it.
    public var value: (ControlID, ControlValue) -> Void = { _, _ in }
    /// A strip's name, by strip id.
    public var name: (String, String) -> Void = { _, _ in }
    /// The console's current state has been read; controls can be used.
    public var synced: () -> Void = {}
    /// Signal levels, by strip ID. Only the strips that changed.
    public var meters: ([String: MeterReading]) -> Void = { _ in }
    /// Text the console reports, by key: "exec.201.cue" (current cue),
    /// "exec.201.active" ("1" when running), "device.cue.active". nil clears it.
    public var info: (String, String?) -> Void = { _, _ in }
    /// `groups` or `deviceControls` changed (e.g. once a console has said
    /// which processing it has).
    public var layoutChanged: () -> Void = {}

    public init() {}
}

/// Speaks one console family's protocol. A driver knows the console's object
/// model (what strips exist and what each control is called on the wire);
/// `Device` handles timing, touch and reconnection on top of it.
@MainActor
public protocol ConsoleDriver: AnyObject {
    var sink: DriverSink { get }
    var groups: [StripGroup] { get }
    /// Controls for the whole device: scene recall, page, command line, blackout.
    var deviceControls: [ControlDescriptor] { get }
    var traits: DriverTraits { get }
    /// Open the connection and read the console's state.
    func start()
    func stop()
    func send(_ id: ControlID, _ value: ControlValue)
    /// The user opened a strip's detail: read its processing now.
    func detailOpened(_ stripID: String)
    /// The user's names, colours and button actions changed.
    func apply(customizations: [String: StripCustomization])
}

public extension ConsoleDriver {
    func detailOpened(_ stripID: String) {}
    func apply(customizations: [String: StripCustomization]) {}
}

public enum Drivers {
    @MainActor
    public static func make(_ config: DeviceConfig, transport: TransportFactory) -> ConsoleDriver {
        switch config.kind {
        case .behringerX32, .behringerXAir: return BehringerDriver(config: config, transport: transport)
        case .allenHeathSQ: return AllenHeathSQDriver(config: config, transport: transport)
        case .allenHeathDLive: return AllenHeathDLiveDriver(config: config, transport: transport)
        case .yamahaRCP: return YamahaRCPDriver(config: config, transport: transport)
        case .grandMA3: return GrandMA3Driver(config: config, transport: transport)
        case .chamsysMagicQ: return MagicQDriver(config: config, transport: transport)
        case .etcEos: return EosDriver(config: config, transport: transport)
        case .artNet: return ArtNetDriver(config: config, transport: transport)
        }
    }
}

/// Runs an action repeatedly on the main actor until stopped.
@MainActor
final class Ticker {
    private var task: Task<Void, Never>?

    func start(every seconds: Double, immediately: Bool = false, _ action: @escaping @MainActor () -> Void) {
        stop()
        if immediately { action() }
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                action()
            }
        }
    }

    func once(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        stop()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { action() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var isRunning: Bool { task != nil }
}

/// Sends a long list of queries a few at a time, so connecting doesn't flood
/// the console (dLive in particular throttles bursts), then calls `done`.
@MainActor
final class QueryPacer {
    private var queue: [Data] = []
    private let ticker = Ticker()
    private let perTick: Int
    private let interval: Double
    private var done: (() -> Void)?

    init(perTick: Int = 24, interval: Double = 0.02) {
        self.perTick = perTick
        self.interval = interval
    }

    func run(_ queries: [Data], send: @escaping @MainActor (Data) -> Void, done: @escaping @MainActor () -> Void) {
        queue = queries
        self.done = done
        ticker.start(every: interval, immediately: true) { [weak self] in
            guard let self else { return }
            for query in self.queue.prefix(self.perTick) { send(query) }
            self.queue.removeFirst(min(self.perTick, self.queue.count))
            if self.queue.isEmpty {
                self.ticker.stop()
                let done = self.done
                self.done = nil
                done?()
            }
        }
    }

    func stop() {
        ticker.stop()
        queue.removeAll()
        done = nil
    }
}

extension TransportState {
    /// The usual mapping for drivers whose console answers once connected.
    var linkState: LinkState {
        switch self {
        case .idle: return .disconnected
        case .opening: return .connecting
        case .ready: return .connecting // connected once the console answers
        case .failed(let reason): return .failed(reason)
        }
    }
}

func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
