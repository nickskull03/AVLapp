import Foundation

/// The app as the lighting controller: each fader is one DMX channel, sent as
/// Art-Net to a node's IP (unicast, so no broadcast entitlement is needed).
/// A master scales every channel and Blackout zeroes them. DMX is streamed
/// continuously, as receivers expect: on every change, and once a second
/// regardless.
@MainActor
final class ArtNetDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = []
    let traits = DriverTraits(reportsChanges: false, readsNames: false)

    static let masterID: ControlID = "master.level"
    static let blackoutID: ControlID = "master.blackout"

    private let transport: Transport
    private let universe: Int
    private let firstChannel: Int
    private var levels: [Double]
    private var master = 1.0
    private var blackout = false
    private var dirty = true
    private var lastSent = ContinuousClock.now
    private var sequence: UInt8 = 0
    private let ticker = Ticker()

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: nil))
        universe = config.universe
        let first = max(1, min(512, config.firstNumber))
        firstChannel = first
        let count = max(1, min(513 - first, config.count))
        levels = Array(repeating: 0, count: count)
        groups = [
            StripGroup(id: "master", title: "Master", strips: [
                Strip(id: "master", name: "Master", style: .master,
                      fader: ControlDescriptor(Self.masterID, "Master", .fader(.percent)),
                      buttons: [ControlDescriptor(Self.blackoutID, "Blackout", .toggle(.blackout))])
            ]),
            StripGroup(id: "dmx", title: "Channels", strips: (0..<count).map { i in
                let channel = first + i
                return Strip(id: "dmx.\(channel)", name: "Ch \(channel)", style: .dimmer,
                             fader: ControlDescriptor(ControlID("dmx.\(channel).level"), "Level", .fader(.percent)))
            })
        ]
        transport.onState = { [weak self] in self?.transportState($0) }
    }

    func start() {
        transport.open()
    }

    func stop() {
        ticker.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id, value) {
        case (Self.masterID, .level(let v)):
            master = clamp01(v)
        case (Self.blackoutID, .on(let on)):
            blackout = on
        case (_, .level(let v)):
            let parts = id.rawValue.split(separator: ".")
            guard parts.count == 3, parts[0] == "dmx", let channel = Int(parts[1]) else { return }
            let i = channel - firstChannel
            guard levels.indices.contains(i) else { return }
            levels[i] = clamp01(v)
        default:
            return
        }
        dirty = true
        flush() // send at once; the ticker covers keep-alive
    }

    /// The DMX slots as they go out, for tests and a monitor.
    var slots: [UInt8] {
        var slots = [UInt8](repeating: 0, count: 512)
        guard !blackout else { return slots }
        for (i, level) in levels.enumerated() {
            slots[firstChannel - 1 + i] = UInt8((level * master * 255).rounded())
        }
        return slots
    }

    // MARK: Private

    private func transportState(_ state: TransportState) {
        switch state {
        case .ready:
            sink.state(.sending)
            // The app owns this state: report it so the faders show it.
            sink.value(Self.masterID, .level(master))
            sink.value(Self.blackoutID, .on(blackout))
            for (i, level) in levels.enumerated() {
                sink.value(ControlID("dmx.\(firstChannel + i).level"), .level(level))
            }
            sink.synced()
            dirty = true
            ticker.start(every: 0.1, immediately: true) { [weak self] in
                guard let self else { return }
                if ContinuousClock.now - self.lastSent > .seconds(1) { self.dirty = true }
                self.flush()
            }
        default:
            ticker.stop()
            sink.state(state.linkState)
        }
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        lastSent = .now
        sequence = sequence == 255 ? 1 : sequence + 1
        // Only as many slots as are in use (rounded up to even), like most controllers.
        let used = min(512, firstChannel - 1 + levels.count)
        transport.send(ArtNet.dmxPacket(universe: universe, sequence: sequence, slots: Array(slots.prefix(max(2, used)))))
    }
}
