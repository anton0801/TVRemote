import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

/// Configures Firebase only when a real `GoogleService-Info.plist` is bundled.
/// `FirebaseApp.configure()` raises an exception without it, so we check first; without a
/// configuration Analytics/Crashlytics/Messaging stay inactive and the app works normally.
/// All automatic collection is disabled in Info.plist until the user opts in.
enum FirebaseBootstrap {
    private(set) static var isConfigured = false

    static var hasConfigurationFile: Bool {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let appID = plist["GOOGLE_APP_ID"] as? String
        else { return false }
        return appID.hasPrefix("1:") && !appID.contains("REPLACE")
    }

    static func configureIfAvailable() {
        #if canImport(FirebaseCore)
        guard !isConfigured, hasConfigurationFile else { return }
        FirebaseApp.configure()
        isConfigured = true
        #endif
    }
}

/// Crash reporting facade over Crashlytics with explicit consent.
@MainActor
final class CrashReportingService {
    private(set) var isEnabled = false

    func setConsent(_ consent: ConsentState) {
        isEnabled = consent.isGranted
        #if canImport(FirebaseCrashlytics)
        guard FirebaseBootstrap.isConfigured else { return }
        let crashlytics = Crashlytics.crashlytics()
        // Reports cached before a decision are discarded, never uploaded later: consent covers
        // crashes from now on.
        if consent != .undecided { crashlytics.deleteUnsentReports() }
        crashlytics.setCrashlyticsCollectionEnabled(isEnabled)
        #endif
    }

    /// Records a handled problem with a stable code only (no messages, addresses or names).
    func recordNonFatal(_ error: AppError, feature: String, platform: TVPlatform?) {
        #if canImport(FirebaseCrashlytics)
        guard isEnabled, FirebaseBootstrap.isConfigured else { return }
        // Deterministic numeric code (hashValue is randomized per launch).
        let numeric = error.code.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 100_000 }
        let nsError = NSError(domain: "app.TVRemote.\(feature)", code: numeric, userInfo: [
            "code": error.code,
            "platform": platform?.rawValue ?? "none",
        ])
        Crashlytics.crashlytics().record(error: nsError)
        #endif
    }

    func setSafeKeys(platform: TVPlatform?, entitlement: String) {
        #if canImport(FirebaseCrashlytics)
        guard isEnabled, FirebaseBootstrap.isConfigured else { return }
        Crashlytics.crashlytics().setCustomValue(platform?.rawValue ?? "none", forKey: "tv_platform")
        Crashlytics.crashlytics().setCustomValue(entitlement, forKey: "access")
        #endif
    }
}
