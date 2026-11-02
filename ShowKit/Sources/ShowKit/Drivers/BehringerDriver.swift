import Foundation

/// Behringer X32/M32 (UDP 10023) and X Air/MR (UDP 10024), over OSC.
///
/// - Fader values are 0–1 floats on the X32 law, which is `AudioTaper`, so
///   they pass straight through.
/// - `…/mix/on` is 1 when the channel is *on* (unmuted).
/// - A query is the address with no arguments; the mixer answers with the value.
/// - The mixer only reports changes made elsewhere for ~10 s after each
///   `/xremote`, so that's renewed every few seconds.
@MainActor
final class BehringerDriver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor]
    let traits = DriverTraits(reportsChanges: true, readsNames: true)

    private enum Target {
        case fader(ControlID)
        case onSwitch(ControlID) // 1 = on, so muted = 0
        case muteSwitch(ControlID) // 1 = muted (mute groups)
        case name(String)
    }

    private let config: DeviceConfig
    private let isX32: Bool
    private let transport: Transport
    private var targets: [String: Target] = [:] // OSC address -> what it is
    private var addresses: [ControlID: String] = [:]
    private let heartbeat = Ticker()
    private let pacer = QueryPacer()
    private var lastHeard: ContinuousClock.Instant?
    private var answered = false

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        self.config = config
        let x32 = config.kind == .behringerX32
        isX32 = x32
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: nil))

        var groups: [StripGroup] = []
        var targets: [String: Target] = [:]
        var addresses: [ControlID: String] = [:]

        // A strip with a fader at `<base>/mix/fader`, on at `<base>/mix/on`
        // (or `<base>/fader` and `<base>/on` for DCAs), name at `<base>/config/name`.
        func strip(_ base: String, _ name: String, _ style: StripStyle, mixPath: Bool = true, confirmMute: Bool = false) -> Strip {
            let id = String(base.dropFirst())
            let levelID = ControlID("\(id).level")
            let muteID = ControlID("\(id).mute")
            let fader = mixPath ? "\(base)/mix/fader" : "\(base)/fader"
            let on = mixPath ? "\(base)/mix/on" : "\(base)/on"
            targets[fader] = .fader(levelID)
            targets[on] = .onSwitch(muteID)
            targets["\(base)/config/name"] = .name(id)
            addresses[levelID] = fader
            addresses[muteID] = on
            return Strip(
                id: id, name: name, style: style,
                fader: ControlDescriptor(levelID, "Fader", .fader(.decibels)),
                buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute), needsConfirmation: confirmMute)]
            )
        }

        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

        func muteGroups(_ count: Int) -> StripGroup {
            StripGroup(id: "mutegroups", title: "Mute Groups", strips: (1...count).map { n in
                let path = "/config/mute/\(n)"
                let muteID = ControlID("mutegroup.\(n).mute")
                targets[path] = .muteSwitch(muteID)
                addresses[muteID] = path
                return Strip(id: "mutegroup.\(n)", name: "Mute \(n)", style: .muteGroup, fader: nil,
                             buttons: [ControlDescriptor(muteID, "Mute", .toggle(.mute))])
            })
        }

        if x32 {
            groups = [
                StripGroup(id: "ch", title: "Inputs", strips: (1...32).map { strip("/ch/\(two($0))", "Ch \($0)", .input) }),
                StripGroup(id: "auxin", title: "Aux Ins", strips: (1...8).map { strip("/auxin/\(two($0))", "Aux \($0)", .input) }),
                StripGroup(id: "fxrtn", title: "FX Returns", strips: (1...8).map { strip("/fxrtn/\(two($0))", "FX \($0)", .fx) }),
                StripGroup(id: "bus", title: "Mix Buses", strips: (1...16).map { strip("/bus/\(two($0))", "Bus \($0)", .bus) }),
                StripGroup(id: "mtx", title: "Matrices", strips: (1...6).map { strip("/mtx/\(two($0))", "Mtx \($0)", .bus) }),
                StripGroup(id: "dca", title: "DCAs", strips: (1...8).map { strip("/dca/\($0)", "DCA \($0)", .dca, mixPath: false) }),
                StripGroup(id: "main", title: "Mains", strips: [
                    strip("/main/st", "Main LR", .master, confirmMute: true),
                    strip("/main/m", "Mono", .master, confirmMute: true)
                ]),
                muteGroups(6)
            ]
        } else {
            groups = [
                StripGroup(id: "ch", title: "Inputs", strips: (1...16).map { strip("/ch/\(two($0))", "Ch \($0)", .input) }
                    + [strip("/rtn/aux", "Aux In", .input)]),
                StripGroup(id: "rtn", title: "FX Returns", strips: (1...4).map { strip("/rtn/\($0)", "FX \($0)", .fx) }),
                StripGroup(id: "bus", title: "Buses", strips: (1...6).map { strip("/bus/\($0)", "Bus \($0)", .bus) }
                    + (1...4).map { strip("/fxsend/\($0)", "FX Send \($0)", .fx) }),
                StripGroup(id: "dca", title: "DCAs", strips: (1...4).map { strip("/dca/\($0)", "DCA \($0)", .dca, mixPath: false) }),
                StripGroup(id: "main", title: "Main", strips: [strip("/lr", "Main LR", .master, confirmMute: true)]),
                muteGroups(4)
            ]
        }
        self.groups = groups
        self.targets = targets
        self.addresses = addresses
        deviceControls = [
            x32
                ? ControlDescriptor("scene", "Recall scene", .number(0...99), needsConfirmation: true)
                : ControlDescriptor("scene", "Load snapshot", .number(1...64), needsConfirmation: true)
        ]

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        answered = false
        lastHeard = nil
        transport.open()
    }

    func stop() {
        heartbeat.stop()
        pacer.stop()
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        if id == "scene", case .number(let n) = value {
            transport.send(OSCMessage(isX32 ? "/-action/goscene" : "/-snap/load", [.int(Int32(n))]).encoded())
            return
        }
        guard let address = addresses[id], let target = targets[address] else { return }
        switch (target, value) {
        case (.fader, .level(let position)):
            transport.send(OSCMessage(address, [.float(Float(clamp01(position)))]).encoded())
        case (.onSwitch, .on(let muted)):
            transport.send(OSCMessage(address, [.int(muted ? 0 : 1)]).encoded())
        case (.muteSwitch, .on(let muted)):
            transport.send(OSCMessage(address, [.int(muted ? 1 : 0)]).encoded())
        default:
            break
        }
    }

    // MARK: Private

    private func transportState(_ state: TransportState) {
        sink.state(state.linkState)
        guard state == .ready else {
            heartbeat.stop()
            return
        }
        // UDP is "ready" at once; the mixer is only there once it answers.
        openedAt = .now
        heartbeat.start(every: 4, immediately: true) { [weak self] in self?.pulse() }
    }

    private var openedAt: ContinuousClock.Instant = .now

    private func pulse() {
        transport.send(OSCMessage("/xremote").encoded())
        transport.send(OSCMessage("/xinfo").encoded())
        let now = ContinuousClock.now
        if let lastHeard {
            if now - lastHeard > .seconds(10) {
                heartbeat.stop()
                sink.state(.failed("The mixer stopped answering"))
            }
        } else if now - openedAt > .seconds(7) {
            heartbeat.stop()
            sink.state(.failed("No answer from \(config.trimmedHost):\(config.port)"))
        }
    }

    private func receive(_ data: Data) {
        lastHeard = .now
        if !answered {
            answered = true
            sink.state(.connected)
            readEverything()
        }
        for message in OSCMessage.decode(data) {
            guard let target = targets[message.address], let argument = message.arguments.first else { continue }
            switch target {
            case .fader(let id):
                if let v = argument.number { sink.value(id, .level(clamp01(v))) }
            case .onSwitch(let id):
                if let v = argument.number { sink.value(id, .on(v < 0.5)) }
            case .muteSwitch(let id):
                if let v = argument.number { sink.value(id, .on(v >= 0.5)) }
            case .name(let stripID):
                if let name = argument.string { sink.name(stripID, name) }
            }
        }
    }

    private func readEverything() {
        let queries = targets.keys.sorted().map { OSCMessage($0).encoded() }
        pacer.run(queries, send: { [weak self] in self?.transport.send($0) }) { [weak self] in
            // Give the last answers a moment to arrive.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.sink.synced()
            }
        }
    }
}
