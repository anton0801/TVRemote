import Foundation
import Observation

enum PaywallContext: String, Sendable, Identifiable {
    case remote, mirroring

    var id: String { rawValue }

    var analytics: AnalyticsEvent.PaywallContext {
        switch self {
        case .remote: .remote
        case .mirroring: .mirroring
        }
    }
}

/// Presents the paywall. Never shown as a blocking wall to anyone with active access.
@MainActor
@Observable
final class PaywallPresenter {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let context: PaywallContext
        /// Feature the user was trying to use; the paywall explains it and returns to it.
        let feature: DiagnosticFeature?
        /// TV the user is working with, for capability-aware copy.
        let deviceID: TVDeviceID?
    }

    private(set) var request: Request?
    /// Short confirmation shown after a verified purchase.
    var purchaseConfirmation: PurchasePlan?
    private let accessState: () -> AccessState
    private let analytics: AnalyticsService

    /// Called before presenting in mirroring context so capture stops first (no paywall on TV).
    var prepareForPresentation: ((PaywallContext) async -> Void)?

    init(accessState: @escaping () -> AccessState, analytics: AnalyticsService) {
        self.accessState = accessState
        self.analytics = analytics
    }

    /// Set synchronously so a second request during preparation (mirroring stopping, sheets
    /// closing) can't present a second paywall.
    private var isPreparing = false

    /// Requests the paywall. Ignored when the user already has access or access is still being
    /// verified (a paying user must never see an offer).
    func present(_ context: PaywallContext, feature: DiagnosticFeature? = nil, deviceID: TVDeviceID? = nil) {
        guard !accessState().hasAccess, accessState() != .verifying, request == nil, !isPreparing else { return }
        isPreparing = true
        Task {
            await prepareForPresentation?(context)
            isPreparing = false
            guard !accessState().hasAccess else { return }
            request = Request(context: context, feature: feature, deviceID: deviceID)
            analytics.log(.paywallViewed(context: context.analytics))
            DiagnosticsLog.shared.record(.paywallShown)
        }
    }

    func dismiss() {
        request = nil
    }

    private static let offeredAfterCheckKey = "paywall.offeredAfterCompatibility"

    /// After the first completed compatibility check, offer the plans once (dismissible;
    /// it never blocks the free check). Returns whether it was presented.
    @discardableResult
    func offerAfterCompatibilityCheck(deviceID: TVDeviceID?, defaults: UserDefaults = .standard) -> Bool {
        guard !accessState().hasAccess, accessState() != .verifying, !defaults.bool(forKey: Self.offeredAfterCheckKey) else { return false }
        defaults.set(true, forKey: Self.offeredAfterCheckKey)
        present(.remote, feature: nil, deviceID: deviceID)
        return true
    }

    func completed(with plan: PurchasePlan) {
        request = nil
        purchaseConfirmation = plan
    }
}
