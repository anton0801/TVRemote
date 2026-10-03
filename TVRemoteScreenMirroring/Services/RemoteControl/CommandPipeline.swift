import Foundation

/// Serial, per-session command queue.
///
/// - Preserves order: commands are sent one at a time in submission order.
/// - Bound to one session: when the user switches TVs the pipeline is cancelled, so a late
///   command can never reach the newly selected TV.
/// - Backpressure: auto-repeat clicks are dropped when the backlog grows; `release` is never
///   dropped so a held key cannot get stuck down on the TV.
actor CommandPipeline {
    typealias FailureHandler = @Sendable (RemoteCommand, AppError) -> Void

    private let session: any TVSession
    private let onFailure: FailureHandler
    private var queue: [(RemoteCommand, KeyAction)] = []
    private var draining = false
    private var cancelled = false
    private(set) var sentCount = 0
    static let maxBacklog = 8

    init(session: any TVSession, onFailure: @escaping FailureHandler) {
        self.session = session
        self.onFailure = onFailure
    }

    func enqueue(_ command: RemoteCommand, _ action: KeyAction) {
        guard !cancelled else { return }
        if action != .release, queue.count >= Self.maxBacklog {
            return // drop; keep latency bounded
        }
        queue.append((command, action))
        if !draining {
            draining = true
            Task { await drain() }
        }
    }

    func cancel() {
        cancelled = true
        queue.removeAll()
    }

    var pendingCount: Int { queue.count }

    private func drain() async {
        while !cancelled, !queue.isEmpty {
            let (command, action) = queue.removeFirst()
            do {
                try await session.send(command, action: action)
                sentCount += 1
            } catch {
                let appError = AppError.wrap(error)
                onFailure(command, appError)
                if appError == .connectionLost {
                    queue.removeAll()
                }
            }
        }
        draining = false
    }
}
