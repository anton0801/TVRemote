import Foundation

/// Thin async wrapper over `URLSessionWebSocketTask` with per-host certificate pinning.
/// One instance = one connection; it is never reused after `close()`.
final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Message: Sendable {
        case text(String)
        case data(Data)
    }

    enum State: Equatable { case idle, connecting, open, closed }

    private let url: URL
    private let pinning: PinningSessionDelegate?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var state: State = .idle
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var closeHandlers: [@Sendable (Error?) -> Void] = []
    /// Keep-alive: a TV that switched off or a phone that left Wi-Fi never sends a close frame.
    private var keepAliveTask: Task<Void, Never>?
    private var awaitingPong = false
    /// Set after the first pong; a peer that never answers pings is not treated as dead.
    private var peerAnswersPings = false
    static let keepAliveInterval: TimeInterval = 10

    let messages: AsyncStream<Message>

    /// - Parameters:
    ///   - pinnedFingerprint: expected certificate fingerprint for `wss` URLs (nil on first use).
    ///   - allowFirstUse: accept an unknown self-signed certificate on a private LAN host (pairing only).
    init(url: URL, pinnedFingerprint: String?, allowFirstUse: Bool) {
        self.url = url
        if url.scheme == "wss", let host = url.host {
            pinning = PinningSessionDelegate(host: host, pinned: pinnedFingerprint, allowFirstUse: allowFirstUse)
        } else {
            pinning = nil
        }
        var continuation: AsyncStream<Message>.Continuation!
        messages = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
        super.init()
        messageContinuation = continuation
    }

    /// Fingerprint of the certificate actually presented (for pinning after pairing).
    var observedFingerprint: String? { pinning?.observedFingerprint }
    var certificateRejected: Bool { pinning?.wasRejected ?? false }

    func onClose(_ handler: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); closeHandlers.append(handler); lock.unlock()
    }

    func connect(timeout: TimeInterval = 8) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        // The request timeout also acts as an idle timeout on WebSocket tasks; TVs send nothing
        // while idle, so keep it long. The handshake has its own `timeout` timer below and
        // liveness is checked with pings.
        configuration.timeoutIntervalForRequest = 3600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024

        lock.withLock {
            self.session = session
            self.task = task
            state = .connecting
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { openContinuation = continuation }
                task.resume()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.failOpen(with: AppError.deviceUnreachable)
                }
            }
        } onCancel: {
            self.close()
        }
        receiveLoop()
    }

    func send(_ text: String) async throws {
        guard let task = currentOpenTask() else { throw AppError.connectionLost }
        try await task.send(.string(text))
    }

    func send(_ data: Data) async throws {
        guard let task = currentOpenTask() else { throw AppError.connectionLost }
        try await task.send(.data(data))
    }

    func close() {
        lock.lock()
        let wasOpen = state != .closed
        state = .closed
        let task = self.task
        let session = self.session
        let handlers = closeHandlers
        closeHandlers.removeAll()
        let pendingOpen = openContinuation
        openContinuation = nil
        let keepAlive = keepAliveTask
        keepAliveTask = nil
        lock.unlock()
        keepAlive?.cancel()
        guard wasOpen else { return }
        pendingOpen?.resume(throwing: AppError.connectionLost)
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        messageContinuation?.finish()
        handlers.forEach { $0(nil) }
    }

    private func currentOpenTask() -> URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return state == .open ? task : nil
    }

    private func failOpen(with error: Error) {
        lock.lock()
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(throwing: error)
        close()
    }

    private func receiveLoop() {
        guard let task = currentOpenTask() else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.messageContinuation?.yield(.text(text))
                self.receiveLoop()
            case .success(.data(let data)):
                self.messageContinuation?.yield(.data(data))
                self.receiveLoop()
            case .success:
                self.receiveLoop()
            case .failure(let error):
                self.finish(with: error)
            }
        }
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard state != .closed else { lock.unlock(); return }
        state = .closed
        let handlers = closeHandlers
        closeHandlers.removeAll()
        let session = self.session
        let keepAlive = keepAliveTask
        keepAliveTask = nil
        lock.unlock()
        keepAlive?.cancel()
        messageContinuation?.finish()
        session?.invalidateAndCancel()
        handlers.forEach { $0(error) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        state = .open
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume()
        startKeepAlive()
    }

    /// Pings the peer; when a peer that has answered before stops answering, the connection is
    /// reported as lost so the app can show it and reconnect instead of silently dropping keys.
    private func startKeepAlive() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
                guard !Task.isCancelled, let self, let socket = self.currentOpenTask() else { return }
                let (unanswered, answersPings) = self.lock.withLock { (self.awaitingPong, self.peerAnswersPings) }
                if unanswered {
                    if answersPings {
                        self.finish(with: AppError.connectionLost)
                        return
                    }
                    // Never answered even once: this TV doesn't support pings — stop probing.
                    return
                }
                self.lock.withLock { self.awaitingPong = true }
                socket.sendPing { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.finish(with: error)
                    } else {
                        self.lock.withLock {
                            self.awaitingPong = false
                            self.peerAnswersPings = true
                        }
                    }
                }
            }
        }
        lock.withLock { keepAliveTask = task }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(with: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let mapped: Error = certificateRejected ? AppError.tlsIdentityMismatch : error
            failOpen(with: mapped)
            finish(with: mapped)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let pinning {
            pinning.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
