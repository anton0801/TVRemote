import Foundation

/// Turns touch-down / touch-up of a remote key into protocol commands.
///
/// - Tap → `click`.
/// - Hold on a repeatable key → real `press`/`release` when the protocol supports it,
///   otherwise rate-limited repeated clicks.
/// - Every hold ends with `release`/stop when the finger lifts, the gesture is cancelled, the
///   app leaves the foreground, the connection drops or the TV changes (`cancelAll`).
@MainActor
final class KeyHoldController {
    static let holdDelay: Duration = .milliseconds(380)
    static let repeatInterval: Duration = .milliseconds(140)
    /// Safety net: no hold lasts longer than this, even if a touch-up is somehow lost.
    /// Long enough to scroll a long list on the TV by holding an arrow; a lost touch-up is
    /// already handled by the key's gesture state, so this is only the last resort.
    nonisolated static let defaultMaximumHold: Duration = .seconds(15)
    private let maximumHold: Duration

    private struct ActiveKey {
        let command: RemoteCommand
        let sessionID: UUID
        var holdTask: Task<Void, Never>?
        var pressedDown = false
        var holding = false
    }

    private var active: ActiveKey?
    private let send: (RemoteCommand, KeyAction) -> Bool
    private let supportsPressRelease: (RemoteCommand) -> Bool
    private let currentSessionID: () -> UUID

    init(send: @escaping (RemoteCommand, KeyAction) -> Bool,
         supportsPressRelease: @escaping (RemoteCommand) -> Bool,
         currentSessionID: @escaping () -> UUID,
         maximumHold: Duration = KeyHoldController.defaultMaximumHold) {
        self.maximumHold = maximumHold
        self.send = send
        self.supportsPressRelease = supportsPressRelease
        self.currentSessionID = currentSessionID
    }

    func touchDown(_ command: RemoteCommand) {
        cancelAll()
        var key = ActiveKey(command: command, sessionID: currentSessionID())
        guard command.isRepeatable else {
            active = key
            return
        }
        key.holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled else { return }
            self?.beginHold()
        }
        active = key
    }

    func touchUp(_ command: RemoteCommand) {
        guard let key = active, key.command == command else { return }
        key.holdTask?.cancel()
        active = nil
        guard key.sessionID == currentSessionID() else { return }
        if key.pressedDown {
            _ = send(command, .release)
        } else if !key.holding {
            _ = send(command, .click)
        }
    }

    /// Stops any hold immediately (background, disconnect, TV switch, gesture cancelled).
    func cancelAll() {
        guard let key = active else { return }
        key.holdTask?.cancel()
        active = nil
        if key.pressedDown, key.sessionID == currentSessionID() {
            _ = send(key.command, .release)
        }
    }

    private func beginHold() {
        guard var key = active, key.sessionID == currentSessionID() else { cancelAll(); return }
        key.holding = true
        if supportsPressRelease(key.command) {
            key.pressedDown = send(key.command, .press)
            let limit = maximumHold
            key.holdTask = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.cancelAll() // sends the release
            }
            active = key
            return
        }
        let command = key.command
        let sessionID = key.sessionID
        let limit = maximumHold
        key.holdTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: limit)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard let self, self.currentSessionID() == sessionID, self.send(command, .click) else { return }
                try? await Task.sleep(for: Self.repeatInterval)
            }
            if !Task.isCancelled { self?.cancelAll() }
        }
        active = key
    }
}
