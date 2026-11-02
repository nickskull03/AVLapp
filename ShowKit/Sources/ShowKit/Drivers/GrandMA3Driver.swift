import Foundation

/// grandMA3 over OSC/UDP. Faders: `/<prefix>/Page<p>/Fader<exec>` with the
/// level scaled to the OSC line's Fader Range. Keys: `/<prefix>/Page<p>/Key<exec>`
/// with 1 (press) and 0 (release). Anything else goes as a command line to
/// `/<prefix>/cmd` (needs Receive Command on in MA3). With Send on, MA3 reports
/// fader moves back to the feedback port.
@MainActor
final class GrandMA3Driver: ConsoleDriver {
    let sink = DriverSink()
    let groups: [StripGroup]
    let deviceControls: [ControlDescriptor] = [
        ControlDescriptor("page", "Page", .number(1...9999)),
        ControlDescriptor("command", "Command", .command)
    ]
    let traits: DriverTraits

    private let config: DeviceConfig
    private let transport: Transport
    private let prefix: String
    private var page: Int
    private var heard = false
    /// "page.exec" -> 0...1, so paging back shows where faders were.
    private var levels: [String: Double] = [:]

    init(config: DeviceConfig, transport makeTransport: TransportFactory) {
        self.config = config
        page = max(1, config.page)
        prefix = config.oscPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        traits = DriverTraits(reportsChanges: config.feedbackPort != 0, readsNames: false)
        let listen: UInt16? = config.feedbackPort == 0 ? nil : config.feedbackPort16
        transport = makeTransport(.udp(host: config.trimmedHost, port: config.port16, listenPort: listen))

        let first = max(1, config.firstNumber)
        let count = max(1, min(90, config.count))
        groups = [StripGroup(id: "exec", title: "Executors", strips: (first..<first + count).map { exec in
            Strip(
                id: "exec.\(exec)", name: "Exec \(exec)", style: .playback,
                fader: ControlDescriptor(ControlID("exec.\(exec).level"), "Fader", .fader(.percent)),
                buttons: [
                    ControlDescriptor(ControlID("exec.\(exec).go"), "Go+", .trigger),
                    ControlDescriptor(ControlID("exec.\(exec).back"), "Go−", .trigger),
                    ControlDescriptor(ControlID("exec.\(exec).key"), "Flash", .momentary)
                ]
            )
        })]

        transport.onState = { [weak self] in self?.transportState($0) }
        transport.onReceive = { [weak self] in self?.receive($0) }
    }

    func start() {
        heard = false
        transport.open()
    }

    func stop() {
        transport.close()
    }

    func send(_ id: ControlID, _ value: ControlValue) {
        switch (id.rawValue, value) {
        case ("page", .number(let newPage)):
            page = max(1, newPage)
            for strip in groups[0].strips {
                let exec = Int(strip.id.dropFirst("exec.".count)) ?? 0
                sink.value(ControlID("\(strip.id).level"), .level(levels["\(page).\(exec)"] ?? 0))
            }
            return
        case ("command", .text(let text)):
            command(text)
            return
        default:
            break
        }
        let parts = id.rawValue.split(separator: ".")
        guard parts.count == 3, let exec = Int(parts[1]) else { return }
        switch (parts[2], value) {
        case ("level", .level(let position)):
            levels["\(page).\(exec)"] = position
            osc("Page\(page)/Fader\(exec)", .float(Float(clamp01(position) * config.faderRange)))
        case ("go", .trigger):
            command("Go+ Page \(page).\(exec)")
        case ("back", .trigger):
            command("Go- Page \(page).\(exec)")
        case ("key", .press(let down)):
            osc("Page\(page)/Key\(exec)", .int(down ? 1 : 0))
        default:
            break
        }
    }

    // MARK: Private

    private func osc(_ rest: String, _ argument: OSCArgument) {
        let address = prefix.isEmpty ? "/\(rest)" : "/\(prefix)/\(rest)"
        transport.send(OSCMessage(address, [argument]).encoded())
    }

    private func command(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        osc("cmd", .string(trimmed))
    }

    private func transportState(_ state: TransportState) {
        switch state {
        case .ready:
            // MA3 doesn't answer OSC, so we can only say we're sending,
            // until feedback arrives. There's no state to read either.
            sink.state(heard ? .connected : .sending)
            sink.synced()
        default:
            sink.state(state.linkState)
        }
    }

    private func receive(_ data: Data) {
        if !heard {
            heard = true
            sink.state(.connected)
        }
        for message in OSCMessage.decode(data) {
            guard case let (msgPage, exec)? = Self.pageAndFader(message.address), config.faderRange > 0,
                  let value = message.arguments.lazy.compactMap(\.number).first else { continue }
            let level = clamp01(value / config.faderRange)
            levels["\(msgPage).\(exec)"] = level
            if msgPage == page { sink.value(ControlID("exec.\(exec).level"), .level(level)) }
        }
    }

    /// Finds "Page<p>/Fader<e>" anywhere in an address.
    static func pageAndFader(_ address: String) -> (Int, Int)? {
        let parts = address.split(separator: "/")
        guard let i = parts.firstIndex(where: { $0.hasPrefix("Page") }), i + 1 < parts.count,
              let page = Int(parts[i].dropFirst(4)), parts[i + 1].hasPrefix("Fader"),
              let exec = Int(parts[i + 1].dropFirst(5)) else { return nil }
        return (page, exec)
    }
}
