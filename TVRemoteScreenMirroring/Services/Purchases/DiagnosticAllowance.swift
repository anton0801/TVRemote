import Foundation
import Observation

/// Free compatibility check before purchase (spec §13). A UX limit, not DRM: stored locally,
/// no fingerprinting. Only successful, confirmed usage is counted; errors, searching, pairing,
/// permission prompts and spinners never consume it. It is not a trial and creates no purchase.
enum DiagnosticFeature: String, Codable, Sendable {
    case remote, photo, mirroring
}

struct DiagnosticUsage: Codable, Equatable, Sendable {
    var remoteSeconds: Double = 0
    var photoShows: Int = 0
    var mirroringSeconds: Double = 0
    /// One technical-failure refund per feature, so a broken test can be retried once.
    var remoteRefundUsed = false
    var mirroringRefundUsed = false
}

@MainActor
@Observable
final class DiagnosticAllowanceStore {
    private(set) var usage: [String: DiagnosticUsage] = [:]
    let limits: AppConfiguration.DiagnosticLimits
    private let store: JSONFileStore<[String: DiagnosticUsage]>

    init(limits: AppConfiguration.DiagnosticLimits, fileName: String = "diagnostic-allowance.json") {
        self.limits = limits
        store = JSONFileStore(fileName: fileName)
        usage = store.load() ?? [:]
    }

    func usage(for device: TVDeviceID) -> DiagnosticUsage {
        usage[device.rawValue] ?? DiagnosticUsage()
    }

    func remaining(_ feature: DiagnosticFeature, for device: TVDeviceID) -> Double {
        let current = usage(for: device)
        switch feature {
        case .remote: return max(0, Double(limits.remoteSeconds) - current.remoteSeconds)
        case .photo: return Double(max(0, limits.photoShows - current.photoShows))
        case .mirroring: return max(0, Double(limits.mirroringSeconds) - current.mirroringSeconds)
        }
    }

    func isExhausted(_ feature: DiagnosticFeature, for device: TVDeviceID) -> Bool {
        remaining(feature, for: device) <= 0
    }

    /// Adds confirmed connected time (called once per second while a remote session is live
    /// and the app is in the foreground).
    func addRemoteTime(_ seconds: Double, for device: TVDeviceID) {
        mutate(device) { $0.remoteSeconds = min(Double(limits.remoteSeconds), $0.remoteSeconds + seconds) }
    }

    /// Counts a photo only after the TV accepted and started showing it.
    func recordPhotoShown(for device: TVDeviceID) {
        mutate(device) { $0.photoShows += 1 }
    }

    /// Total free mirroring time used on this TV (previous sessions + the current one), counted
    /// from the TV's first confirmed frame. Never decreases except through the one refund.
    func setMirroringUsed(_ seconds: Double, for device: TVDeviceID) {
        mutate(device) { $0.mirroringSeconds = min(Double(limits.mirroringSeconds), max($0.mirroringSeconds, seconds)) }
    }

    /// A test that failed for a technical reason early on may be retried once.
    func refundAfterTechnicalFailure(_ feature: DiagnosticFeature, usedSeconds: Double, for device: TVDeviceID) {
        guard usedSeconds < 15 else { return }
        mutate(device) { value in
            switch feature {
            case .remote where !value.remoteRefundUsed:
                value.remoteSeconds = max(0, value.remoteSeconds - usedSeconds)
                value.remoteRefundUsed = true
            case .mirroring where !value.mirroringRefundUsed:
                value.mirroringSeconds = max(0, value.mirroringSeconds - usedSeconds)
                value.mirroringRefundUsed = true
            default:
                break
            }
        }
    }

    private func mutate(_ device: TVDeviceID, _ change: (inout DiagnosticUsage) -> Void) {
        var value = usage(for: device)
        change(&value)
        usage[device.rawValue] = value
        store.save(usage)
    }
}

/// Decides whether a feature may be used right now.
@MainActor
@Observable
final class AccessController {
    enum Decision: Equatable {
        /// Remote Pro active (or verification pending within the allowed window).
        case full
        /// Free diagnostic with the remaining amount (seconds or shows).
        case diagnostic(remaining: Double)
        /// Diagnostic used up: Remote Pro needed.
        case requiresPro
    }

    let allowance: DiagnosticAllowanceStore
    private let accessState: () -> AccessState

    init(allowance: DiagnosticAllowanceStore, accessState: @escaping () -> AccessState) {
        self.allowance = allowance
        self.accessState = accessState
    }

    /// Remote Pro active or being verified: paying users are never locked out by a pending
    /// refresh. Use for Pro-only features (video, slideshow); diagnostic features use `decision`.
    var hasPro: Bool {
        if case .inactive = accessState() { return false }
        return true
    }

    func decision(_ feature: DiagnosticFeature, device: TVDeviceID) -> Decision {
        switch accessState() {
        case .active, .verifying:
            // Verifying is bounded by `EntitlementResolver.resolveFromCache`; a paying user is
            // never locked out by a transient refresh failure.
            return .full
        case .inactive:
            let remaining = allowance.remaining(feature, for: device)
            return remaining > 0 ? .diagnostic(remaining: remaining) : .requiresPro
        }
    }
}
