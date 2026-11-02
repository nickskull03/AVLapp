import Foundation

/// How a driver wants to reach its console.
public enum TransportSpec: Equatable, Sendable {
    /// Datagrams to host:port. Replies to our own socket arrive too. With
    /// `listenPort`, also accepts datagrams sent to that local port (for
    /// consoles that send feedback to a fixed port of yours).
    case udp(host: String, port: UInt16, listenPort: UInt16?)
    /// A byte stream. Framing is the driver's business.
    case tcp(host: String, port: UInt16)
}

public enum TransportState: Equatable, Sendable {
    case idle
    case opening
    case ready
    case failed(String)
}

/// A way to exchange bytes with a console. Callbacks arrive on the main actor.
/// UDP delivers one datagram per `onReceive`; TCP delivers stream chunks.
@MainActor
public protocol Transport: AnyObject {
    var onState: (TransportState) -> Void { get set }
    var onReceive: (Data) -> Void { get set }
    func open()
    func close()
    func send(_ data: Data)
}

public typealias TransportFactory = @MainActor (TransportSpec) -> Transport
