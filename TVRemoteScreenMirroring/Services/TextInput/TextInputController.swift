import Foundation
import Observation

/// Pure planning of text operations (unit-tested).
enum TextDiff {
    /// Operations that turn `sent` (what the TV field is believed to contain) into `desired`
    /// for an append/delete protocol. Works on grapheme clusters so "é", "ß", emoji and
    /// combining sequences are never split. Falls back to a full replace for mid-string edits
    /// or deletions whose character count the protocol could interpret ambiguously.
    static func appendDeleteOperations(from sent: String, to desired: String) -> [TextInputOperation] {
        if sent == desired { return [] }
        let old = Array(sent), new = Array(desired)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }

        let removed = old[prefix...]
        let added = String(new[prefix...])
        if removed.isEmpty {
            return [.append(added)]
        }
        // Only delete when each removed character is one Unicode scalar in the BMP, so that
        // "count" means the same thing in UTF-16 and in characters.
        let unambiguous = removed.allSatisfy { $0.unicodeScalars.count == 1 && $0.utf16.count == 1 }
        guard unambiguous, removed.count <= 16 else { return [.replaceAll(desired)] }
        var operations: [TextInputOperation] = [.deleteBackward(count: removed.count)]
        if !added.isEmpty { operations.append(.append(added)) }
        return operations
    }
}

/// Keyboard feature: keeps phone text and TV field in sync without duplicates.
///
/// Sends are serialized; every send is bound to the session that was active when typing
/// started. After a reconnect or an unknown result nothing is re-sent automatically — the
/// user sees the state and can resend explicitly.
@MainActor
@Observable
final class TextInputController {
    enum Status: Equatable {
        case idle
        case sending
        case synced
        case failed(AppError)
        /// A send may or may not have reached the TV (timeout, connection drop).
        case unknown
    }

    private(set) var status: Status = .idle
    private(set) var text = ""
    private(set) var mode: TextInputMode?

    private var confirmed = ""
    private var confirmedKnown = true
    private var boundSessionID: UUID?
    private var senderTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var submitRequested = false

    private let connection: ConnectionManager
    private let analytics: AnalyticsService

    init(connection: ConnectionManager, analytics: AnalyticsService) {
        self.connection = connection
        self.analytics = analytics
    }

    var textFieldState: TVTextFieldState { connection.textFieldState }

    /// Call when the keyboard screen opens for the current session.
    func begin() {
        guard let session = connection.session else {
            mode = nil
            return
        }
        if boundSessionID != connection.sessionID {
            reset()
            boundSessionID = connection.sessionID
        }
        mode = session.textInputMode
    }

    /// Access gate checked on every send (the free check can run out while the keyboard is
    /// open). Returns false — and shows the paywall — when Remote Pro is needed.
    var isAllowed: () -> Bool = { true }

    /// The phone field changed. `isComposing` = the keyboard has marked (uncommitted) text.
    func update(_ newText: String, isComposing: Bool) {
        text = newText
        guard !isComposing, let mode, mode.isLive else { return }
        guard sessionStillValid(), isAllowed() else { return }
        debounceTask?.cancel()
        let delay: Duration = mode == .replaceField ? .milliseconds(250) : .milliseconds(80)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scheduleSend()
        }
    }

    /// Explicit send (send-completed mode) or "Search/Enter".
    func submit() {
        guard sessionStillValid(), isAllowed() else { return }
        submitRequested = true
        debounceTask?.cancel()
        scheduleSend()
    }

    /// Resend the whole text after an unknown result (explicit user action).
    func resend() {
        guard sessionStillValid(), isAllowed() else { return }
        confirmedKnown = false
        scheduleSend()
    }

    func clear() {
        text = ""
        if mode?.isLive == true { scheduleSend() }
    }

    func reset() {
        senderTask?.cancel()
        debounceTask?.cancel()
        senderTask = nil
        text = ""
        confirmed = ""
        confirmedKnown = true
        submitRequested = false
        status = .idle
    }

    private func sessionStillValid() -> Bool {
        guard connection.state.isConnected, boundSessionID == connection.sessionID else {
            status = .failed(.connectionLost)
            return false
        }
        return true
    }

    private func scheduleSend() {
        guard senderTask == nil else { return } // the running loop picks up the latest text
        senderTask = Task { [weak self] in
            await self?.sendLoop()
            self?.senderTask = nil
        }
    }

    private func sendLoop() async {
        guard let mode, let session = connection.session, boundSessionID == connection.sessionID else { return }
        let platform = session.platform
        while !Task.isCancelled {
            let target = text
            let operations: [TextInputOperation]
            switch mode {
            case .appendAndDelete:
                operations = confirmedKnown ? TextDiff.appendDeleteOperations(from: confirmed, to: target)
                                            : [.replaceAll(target)]
            case .replaceField:
                operations = (confirmedKnown && confirmed == target) ? [] : [.replaceAll(target)]
            case .sendCompleted:
                operations = submitRequested && !target.isEmpty ? [.replaceAll(target)] : []
            }
            let wantsSubmit = submitRequested
            if operations.isEmpty && !wantsSubmit { break }
            status = .sending
            do {
                for operation in operations {
                    guard boundSessionID == connection.sessionID else { throw AppError.connectionLost }
                    try await session.performText(operation)
                }
                confirmed = target
                confirmedKnown = true
                if wantsSubmit {
                    submitRequested = false
                    try await session.performText(.submit)
                }
                status = .synced
                DiagnosticsLog.shared.record(.textSent, platform: platform)
                if wantsSubmit || mode == .sendCompleted {
                    analytics.log(.textSendResult(platform: platform, result: .success, errorCode: nil))
                }
            } catch {
                let appError = AppError.wrap(error)
                submitRequested = false
                if appError == .commandTimedOut || appError == .connectionLost {
                    confirmedKnown = false
                    status = .unknown
                    analytics.log(.textSendResult(platform: platform, result: .unconfirmed, errorCode: appError.code))
                } else {
                    let mapped: AppError = appError == .commandNotSupported ? .textFieldNotFocused : appError
                    status = .failed(mapped)
                    analytics.log(.textSendResult(platform: platform, result: .failure, errorCode: mapped.code))
                }
                DiagnosticsLog.shared.record(.textFailed, platform: platform, error: appError)
                return
            }
            // Enter pressed while this chunk was being sent must still be delivered.
            if text == target && !submitRequested { break }
        }
    }
}
