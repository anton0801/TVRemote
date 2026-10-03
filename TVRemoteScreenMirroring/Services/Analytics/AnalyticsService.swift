import Foundation
import os
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

protocol AnalyticsProvider: Sendable {
    func setCollectionEnabled(_ enabled: Bool)
    func log(name: String, parameters: [String: Any])
    /// Deletes data collected so far on this device (consent withdrawn).
    func resetData()
}

extension AnalyticsProvider {
    func resetData() {}
}

/// Analytics facade. Nothing is sent unless the user opted in (`ConsentState.granted`).
/// Undecided behaves like denied. Uses Google Analytics for Firebase when a real Firebase
/// configuration is bundled; otherwise events go only to the local debug log (DEBUG builds).
@MainActor
final class AnalyticsService {
    private var provider: AnalyticsProvider
    private(set) var isEnabled = false
    private let logger = Logger(subsystem: "app.TVRemoteScreenMirroring", category: "analytics")

    init(provider: AnalyticsProvider) {
        self.provider = provider
    }

    var providerName: String { String(describing: type(of: provider)) }

    func setConsent(_ consent: ConsentState) {
        let wasEnabled = isEnabled
        isEnabled = consent.isGranted
        provider.setCollectionEnabled(isEnabled)
        if wasEnabled, consent == .denied { provider.resetData() }
    }

    func log(_ event: AnalyticsEvent) {
        #if DEBUG
        logger.debug("event \(event.name, privacy: .public) enabled=\(self.isEnabled, privacy: .public)")
        #endif
        guard isEnabled else { return }
        provider.log(name: event.name, parameters: event.parameters.mapValues(\.foundationValue))
    }
}

/// Used when Firebase is not configured. Records nothing remotely.
struct LocalDebugAnalyticsProvider: AnalyticsProvider {
    func setCollectionEnabled(_ enabled: Bool) {}
    func log(name: String, parameters: [String: Any]) {}
    func resetData() {}
}

#if canImport(FirebaseAnalytics)
struct FirebaseAnalyticsProvider: AnalyticsProvider {
    func setCollectionEnabled(_ enabled: Bool) {
        Analytics.setAnalyticsCollectionEnabled(enabled)
        // Analytics storage only; advertising signals always denied (no ads, no IDFA).
        Analytics.setConsent([
            .analyticsStorage: enabled ? .granted : .denied,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
    }

    func log(name: String, parameters: [String: Any]) {
        Analytics.logEvent(name, parameters: parameters)
    }

    func resetData() {
        Analytics.resetAnalyticsData()
    }
}
#endif
