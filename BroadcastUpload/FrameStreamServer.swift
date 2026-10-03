import Foundation
import Network

/// WebSocket endpoint the receiver page connects to. Exactly one client: the selected TV,
/// presenting the session token as its subprotocol. Frames are only sent while fewer than
/// `maxInFlight` are unacknowledged, so latency stays bounded (newest frame wins).
final class FrameStreamServer: @unchecked Sendable {
    enum Event {
        case clientConnected
        case frameAcknowledged(sequence: UInt32, roundTripMs: Int)
        case clientDisconnected
    }

    private let queue = DispatchQueue(label: "frame.stream.server")
    private let token: String
    private let allowedHost: String
    private var listener: NWListener?
    private var client: NWConnection?
    private let lock = NSLock()
    private var lastSent: UInt32 = 0
    private var lastAcked: UInt32 = 0
    private var sequence: UInt32 = 0
    private let clock = DispatchTime.now()
    let maxInFlight: UInt32 = 2
    var onEvent: ((Event) -> Void)?

    init(token: String, allowedHost: String) {
        self.token = token
        self.allowedHost = allowedHost
    }

    func start() async throws -> UInt16 {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 1024 * 1024
        let expected = "t\(token)"
        options.setClientRequestHandler(queue) { subprotocols, _ in
            subprotocols.contains(expected)
                ? NWProtocolWebSocket.Response(status: .accept, subprotocol: expected)
                : NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    var hasClient: Bool { lock.withLock { client != nil } }

    /// True if another frame may be sent now.
    var canSend: Bool {
        lock.withLock { client != nil && lastSent &- lastAcked < maxInFlight }
    }

    func send(jpeg: Data, quarterTurns: UInt8) {
        let (connection, header): (NWConnection?, Data) = lock.withLock {
            sequence &+= 1
            lastSent = sequence
            let now = UInt32(truncatingIfNeeded: (DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1_000_000)
            return (client, MirroringFrameHeader.make(sequence: sequence, timestampMs: now, quarterTurns: quarterTurns))
        }
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: header + jpeg, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.drop(connection) }
        })
    }

    func sendText(_ text: String, completion: (() -> Void)? = nil) {
        guard let connection = lock.withLock({ client }) else { completion?(); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in completion?() })
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let connection = lock.withLock { () -> NWConnection? in
            defer { client = nil }
            return client
        }
        connection?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let remoteHost: String? = {
            if case .hostPort(let host, _) = connection.endpoint {
                return "\(host)".split(separator: "%").first.map(String.init)
            }
            return nil
        }()
        let permitted = remoteHost == allowedHost || remoteHost == "::ffff:\(allowedHost)"
        let alreadyConnected = lock.withLock { client != nil }
        guard permitted, !alreadyConnected else {
            connection.cancel()
            return
        }
        lock.withLock {
            client = connection
            lastAcked = sequence
            lastSent = sequence
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.onEvent?(.clientConnected)
                self.receive(connection)
            case .failed, .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                _ = error
                self.drop(connection)
                return
            }
            if let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if metadata.opcode == .close {
                    self.drop(connection)
                    return
                }
                if metadata.opcode == .text, let ack = MirroringFrameHeader.parseAck(String(decoding: data, as: UTF8.self)) {
                    let now = UInt32(truncatingIfNeeded: (DispatchTime.now().uptimeNanoseconds - self.clock.uptimeNanoseconds) / 1_000_000)
                    self.lock.withLock { if ack.sequence &- self.lastAcked < 1_000_000 { self.lastAcked = ack.sequence } }
                    self.onEvent?(.frameAcknowledged(sequence: ack.sequence, roundTripMs: Int(now &- ack.timestampMs)))
                }
            }
            self.receive(connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        let wasClient = lock.withLock { () -> Bool in
            guard client === connection else { return false }
            client = nil
            return true
        }
        connection.cancel()
        if wasClient { onEvent?(.clientDisconnected) }
    }
}
