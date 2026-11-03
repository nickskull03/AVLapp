#if canImport(Network)
import Foundation
import Network

public enum NetworkTransports {
    /// The real transports, on Apple's Network framework.
    @MainActor
    public static func make(_ spec: TransportSpec) -> Transport {
        switch spec {
        case let .udp(host, port, listenPort):
            return UDPTransport(host: host, port: port, listenPort: listenPort)
        case let .tcp(host, port):
            return TCPTransport(host: host, port: port)
        case let .webSocket(url):
            return WebSocketTransport(url: URL(string: url))
        }
    }
}

/// UDP to one host and port. Network-framework work happens on a private
/// queue; callbacks hop to the main actor.
@MainActor
final class UDPTransport: Transport {
    var onState: (TransportState) -> Void = { _ in }
    var onReceive: (Data) -> Void = { _ in }

    private let host: String
    private let port: UInt16
    private let listenPort: UInt16?
    private let queue = DispatchQueue(label: "showkit.udp")
    private var connection: NWConnection?
    private var listener: NWListener?
    private var generation = 0

    init(host: String, port: UInt16, listenPort: UInt16?) {
        self.host = host
        self.port = port
        self.listenPort = listenPort
    }

    func open() {
        close()
        generation += 1
        let generation = self.generation
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState(.failed("Set the console's IP address"))
            return
        }
        onState(.opening)

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready: self.onState(.ready)
                case .failed(let error), .waiting(let error): self.onState(.failed(error.localizedDescription))
                default: break
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, generation: generation)
        self.connection = connection

        if let listenPort, listenPort != 0, let nwListenPort = NWEndpoint.Port(rawValue: listenPort) {
            do {
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: nwListenPort)
                listener.newConnectionHandler = { [weak self] incoming in
                    incoming.start(queue: self?.queue ?? .main)
                    Task { @MainActor in
                        guard let self, self.generation == generation else { incoming.cancel(); return }
                        self.receive(on: incoming, generation: generation)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            self.onState(.failed("Feedback port \(listenPort): \(error.localizedDescription)"))
                        }
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                onState(.failed("Feedback port \(listenPort): \(error.localizedDescription)"))
            }
        }
    }

    func close() {
        generation += 1
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        onState(.idle)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    private nonisolated func receive(on connection: NWConnection, generation: Int) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.onReceive(data)
                }
            }
            if error == nil {
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.receive(on: connection, generation: generation)
                }
            }
        }
    }
}

/// A TCP connection with Nagle off, keepalives on and a short connect timeout.
/// It doesn't reconnect by itself; `Device` decides when to try again.
@MainActor
final class TCPTransport: Transport {
    var onState: (TransportState) -> Void = { _ in }
    var onReceive: (Data) -> Void = { _ in }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "showkit.tcp")
    private var connection: NWConnection?
    private var generation = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func open() {
        close()
        generation += 1
        let generation = self.generation
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState(.failed("Set the console's IP address"))
            return
        }
        onState(.opening)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready: self.onState(.ready)
                case .failed(let error), .waiting(let error):
                    self.onState(.failed(error.localizedDescription))
                    self.connection?.cancel()
                    self.connection = nil
                default: break
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, generation: generation)
        self.connection = connection
    }

    func close() {
        generation += 1
        connection?.cancel()
        connection = nil
        onState(.idle)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private nonisolated func receive(on connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let data, !data.isEmpty { self.onReceive(data) }
                if isComplete || error != nil {
                    self.onState(.failed(error?.localizedDescription ?? "The console closed the connection"))
                    self.connection?.cancel()
                    self.connection = nil
                } else {
                    self.receive(on: connection, generation: generation)
                }
            }
        }
    }
}
/// A WebSocket on URLSession. Pings every 5 s, so a console that's gone away
/// shows as failed rather than hanging.
@MainActor
final class WebSocketTransport: NSObject, Transport, URLSessionWebSocketDelegate {
    var onState: (TransportState) -> Void = { _ in }
    var onReceive: (Data) -> Void = { _ in }

    private let url: URL?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let pinger = Ticker()

    init(url: URL?) {
        self.url = url
    }

    func open() {
        close()
        guard let url, url.host != nil, url.host != "" else {
            onState(.failed("Set the console's IP address"))
            return
        }
        onState(.opening)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20 // a whole show can arrive in one message
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func close() {
        pinger.stop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onState(.idle)
    }

    func send(_ data: Data) {
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func fail(_ reason: String, task failed: URLSessionWebSocketTask) {
        guard failed === task else { return }
        pinger.stop()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        onState(.failed(reason))
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.onReceive(Data(text.utf8))
                    case .data(let data): self.onReceive(data)
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure(let error):
                    self.fail(error.localizedDescription, task: task)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            self.onState(.ready)
            self.pinger.start(every: 5) { [weak self] in
                guard let self, let task = self.task else { return }
                task.sendPing { error in
                    guard let error else { return }
                    Task { @MainActor in self.fail(error.localizedDescription, task: task) }
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in self.fail("The console closed the connection", task: webSocketTask) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let socket = task as? URLSessionWebSocketTask else { return }
        Task { @MainActor in self.fail(error.localizedDescription, task: socket) }
    }
}
#endif
