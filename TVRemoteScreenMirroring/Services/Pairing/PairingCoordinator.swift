import Foundation
import Observation

/// Bridges adapter pairing callbacks to SwiftUI. Exactly one pairing prompt at a time.
@MainActor
@Observable
final class PairingCoordinator: PairingInteraction {
    enum Prompt: Equatable {
        case none
        case confirmOnTV
        case enterPIN(attempt: Int)
    }

    private(set) var prompt: Prompt = .none
    private var pinContinuation: CheckedContinuation<String, Error>?

    func showConfirmOnTV() {
        if case .enterPIN = prompt { return }
        prompt = .confirmOnTV
    }

    func requestPIN(attempt: Int) async throws -> String {
        pinContinuation?.resume(throwing: CancellationError())
        prompt = .enterPIN(attempt: attempt)
        return try await withCheckedThrowingContinuation { pinContinuation = $0 }
    }

    func submitPIN(_ pin: String) {
        let continuation = pinContinuation
        pinContinuation = nil
        prompt = .confirmOnTV
        continuation?.resume(returning: pin)
    }

    func cancel() {
        let continuation = pinContinuation
        pinContinuation = nil
        prompt = .none
        continuation?.resume(throwing: CancellationError())
    }

    func reset() {
        cancel()
    }
}

/// Used by background reconnects: never shows UI. A TV that asks to be paired again makes the
/// reconnect fail with "Pair again" instead of popping a prompt over whatever the user is doing.
final class SilentPairingInteraction: PairingInteraction, @unchecked Sendable {
    func showConfirmOnTV() {}

    func requestPIN(attempt: Int) async throws -> String {
        throw AppError.pairingTokenRevoked
    }
}
