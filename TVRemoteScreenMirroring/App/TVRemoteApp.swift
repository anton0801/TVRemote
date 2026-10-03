import SwiftUI
import UIKit
import Firebase
import FirebaseMessaging

@main
struct TVRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// Unit tests run inside the app process; the app then stays idle so tests are isolated.
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && !ProcessInfo.processInfo.arguments.contains("-UITests")

    init() {
        // UI tests start from a clean state; this must happen before AppModel reads anything.
        if ProcessInfo.processInfo.arguments.contains("-UITestsResetState") {
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
            for name in ["devices.json", "diagnostic-allowance.json", "bonus-result.json", "bonus-visits.json", "support-draft.json"] {
                try? FileManager.default.removeItem(at: JSONFileStore<Int>.applicationSupport.appendingPathComponent(name))
            }
            // Pairings and the cached entitlement live in the Keychain; a stale mirroring request
            // lives in the app group — clear them too so every UI test starts truly clean.
            KeychainStore().removeAll()
            KeychainStore(service: "app.TVRemoteScreenMirroring.entitlement").removeAll()
            MirroringRequest.clear()
        }
        AppAppearance.apply()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                Color.clear
            } else {
                appContent
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Self.isRunningUnitTests else { return }
            model.scenePhaseChanged(phase)
        }
    }

    private var appContent: some View {
        RootView()
            .environment(model)
            .environment(model.localization)
            .environment(\.locale, model.localization.locale)
            .preferredColorScheme(.dark)
            .tint(.appAccent)
            .onAppear {
                appDelegate.model = model
                model.start()
            }
    }
}

/// Needed for APNs registration because Firebase method swizzling is disabled.
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated {
            model?.notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
    }
}
#endif
