import Foundation
import Network
import Security

/// TCP+TLS byte stream built on Network framework, with an optional client identity and
/// trust-on-first-use pinning of the server certificate. Used by the Android TV protocol.
final class TLSStreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tls.stream")
    private let host: String
    private let lock = NSLock()
    private var _serverCertificate: SecCertificate?
    private var _rejected = false
    private var readyContinuation: CheckedContinuation<Void, Error>?
    /// Unbounded: dropping bytes would corrupt the varint framing of the whole stream.
    private let dataChannel = EventChannel<Data>(buffer: nil)
    private var isCancelled = false

    /// Raw decrypted bytes from the server. Finishes when the connection ends.
    var incoming: AsyncStream<Data> { dataChannel.stream }

    init(host: String, port: UInt16, identity: SecIdentity?, pinnedFingerprint: String?, allowFirstUse: Bool) {
        self.host = host
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let identity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        let verifyQueue = DispatchQueue(label: "tls.verify")
        weak var weakSelf: TLSStreamConnection?
        sec_protocol_options_set_verify_block(options, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            let leaf = CertificatePinning.leafCertificate(of: trust)
            let fingerprint = leaf.map(CertificatePinning.sha256Fingerprint)
            let decision = CertificatePinning.evaluate(host: host, presentedFingerprint: fingerprint, pinned: pinnedFingerprint, allowFirstUse: allowFirstUse)
            switch decision {
            case .accept:
                weakSelf?.setServerCertificate(leaf)
                complete(true)
            case .reject:
                weakSelf?.markRejected()
                complete(false)
            }
        }, verifyQueue)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        weakSelf = self
    }

    var serverCertificate: SecCertificate? {
        lock.lock(); defer { lock.unlock() }
        return _serverCertificate
    }

    var certificateRejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _rejected
    }

    private func setServerCertificate(_ certificate: SecCertificate?) {
        lock.lock(); _serverCertificate = certificate; lock.unlock()
    }

    private func markRejected() {
        lock.lock(); _rejected = true; lock.unlock()
    }

    func start(timeout: TimeInterval = 8) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { readyContinuation = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.resumeReady(throwing: AppError.deviceUnreachable)
                }
            }
        } onCancel: {
            self.cancel()
        }
        receive()
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func cancel() {
        let shouldCancel: Bool = lock.withLock {
            defer { isCancelled = true }
            return !isCancelled
        }
        guard shouldCancel else { return }
        connection.cancel()
        dataChannel.continuation.finish()
        resumeReady(throwing: AppError.connectionLost)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            resumeReady(throwing: nil)
        case .failed(let error), .waiting(let error):
            let mapped: Error
            if certificateRejected {
                mapped = AppError.tlsIdentityMismatch
            } else if case .posix(let code) = error, code == .ECONNREFUSED {
                mapped = AppError.deviceUnreachable
            } else if case .tls = error {
                mapped = AppError.pairingTokenRevoked
            } else {
                mapped = AppError.deviceUnreachable
            }
            resumeReady(throwing: mapped)
            cancel()
        case .cancelled:
            dataChannel.continuation.finish()
        default:
            break
        }
    }

    private func resumeReady(throwing error: Error?) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { readyContinuation = nil }
            return readyContinuation
        }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.dataChannel.continuation.yield(data) }
            if isComplete || error != nil {
                self.cancel()
            } else {
                self.receive()
            }
        }
    }
}

extension SecCertificate {
    /// RSA public key (modulus, exponent) of the certificate, if RSA.
    var rsaPublicKeyComponents: (modulus: Data, exponent: Data)? {
        guard let key = SecCertificateCopyKey(self),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return DER.parseRSAPublicKey(data)
    }
}
