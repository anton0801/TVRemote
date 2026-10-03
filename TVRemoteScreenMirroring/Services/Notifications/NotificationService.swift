import Foundation
import Observation
import UIKit
import UserNotifications
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// What the Notifications screen shows about the iOS permission (pure, unit-tested).
enum NotificationPermission: Equatable, Sendable {
    case notAsked, allowed, provisional, denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .allowed
        case .provisional, .ephemeral: self = .provisional
        case .denied: self = .denied
        default: self = .notAsked
        }
    }

    /// Categories can be switched unless iOS blocks notifications for the app.
    var allowsToggling: Bool { self != .denied }
}

/// Delivery registration for remote categories, independent from the iOS permission.
enum RemoteSyncState: Equatable, Sendable {
    /// Nothing to sync (no remote category on).
    case idle
    case syncing
    case synced
    /// Preferences saved on this iPhone; this build has no push service configured.
    case notConfigured
    /// Saved locally; registration will be retried (e.g. offline).
    case pending
    case failed

    /// Offline errors are retried quietly; anything else is shown with a retry action.
    static func after(_ error: Error) -> RemoteSyncState {
        (error as NSError).domain == NSURLErrorDomain ? .pending : .failed
    }
}

enum NotificationCategory: Sendable { case trialReminder, service, offers }

/// Screens a notification may open. Payloads can only select one of these — never a URL,
/// a TV command, a purchase or anything that grants access.
enum NotificationDestination: String, Sendable {
    case offers, remotePro, help, serviceUpdate
}

/// Local trial reminders + Firebase Cloud Messaging with explicit, separate consents.
///
/// - iOS permission, service messages and marketing consent are independent states.
/// - FCM registration happens only after the user enables a remote category; disabling all
///   remote categories unregisters the installation. Topic subscriptions (`service-<lang>`, `offers-<lang>`)
///   mirror consent so console campaigns only reach opted-in installs.
/// - Offers are re-validated on open; a notification never grants Remote Pro.
@MainActor
@Observable
final class NotificationService: NSObject {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var pendingDestination: NotificationDestination?
    /// Bumped on every tap, so tapping the same destination twice is still noticed.
    private(set) var destinationSignal = 0
    private(set) var fcmTokenAvailable = false
    private(set) var syncState: RemoteSyncState = .idle

    var permission: NotificationPermission { NotificationPermission(authorization) }
    private static let pendingSyncKey = "notifications.pendingSync"

    private let settings: AppSettings
    private let configuration: AppConfiguration.Notifications
    private let analytics: AnalyticsService
    private let center = UNUserNotificationCenter.current()
    private var subscribedTopics: Set<String> = []
    static let trialReminderID = "trial-reminder"

    init(settings: AppSettings, configuration: AppConfiguration.Notifications, analytics: AnalyticsService) {
        self.settings = settings
        self.configuration = configuration
        self.analytics = analytics
        super.init()
        // Set during app init so a tap on a notification that launched the app is delivered.
        center.delegate = self
    }

    /// Turns a category on or off. Turning on asks iOS first when needed; if iOS refuses,
    /// the preference stays off. Turning off is saved immediately and unsubscribed.
    /// Returns the value that was actually stored.
    @discardableResult
    func setCategory(_ category: NotificationCategory, enabled: Bool) async -> Bool {
        if enabled {
            guard await requestPermission() else {
                store(category, false)
                return false
            }
        }
        store(category, enabled)
        switch category {
        case .trialReminder:
            break // the caller reschedules the local reminder
        case .service, .offers:
            await applyRemotePreferences()
        }
        return enabled
    }

    private func store(_ category: NotificationCategory, _ value: Bool) {
        switch category {
        case .trialReminder: settings.trialReminderEnabled = value
        case .service: settings.serviceNotificationsEnabled = value
        case .offers: settings.marketingNotificationsConsent = value ? .granted : .denied
        }
    }

    /// Retries a registration that failed or was postponed (called on launch / foreground).
    func retryPendingSync() async {
        guard UserDefaults.standard.bool(forKey: Self.pendingSyncKey) || syncState == .failed || syncState == .pending else { return }
        await applyRemotePreferences()
    }

    func start() {
        #if canImport(FirebaseMessaging)
        if FirebaseBootstrap.isConfigured {
            Messaging.messaging().delegate = self
            Messaging.messaging().isAutoInitEnabled = false
        }
        #endif
        Task {
            await refreshAuthorization()
            // Re-apply saved choices (topics are per install) or show that delivery isn't configured.
            if settings.serviceNotificationsEnabled || settings.marketingNotificationsConsent.isGranted {
                await applyRemotePreferences()
            }
        }
    }

    var remoteCategoriesAvailable: Bool { FirebaseBootstrap.isConfigured }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks for iOS permission after an explicit user choice. Returns whether it's granted.
    func requestPermission() async -> Bool {
        await refreshAuthorization()
        if authorization == .authorized || authorization == .provisional { return true }
        guard authorization == .notDetermined else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        analytics.log(.notificationPermissionResult(granted: granted))
        DiagnosticsLog.shared.record(.notificationPermissionResult)
        return granted
    }

    // MARK: Trial reminder (local)

    /// Schedules (or removes) the reminder for the current free period.
    /// 7-day period → 48 h before the end; 3-day period → 36 h before, leaving time to cancel
    /// at least 24 h before the charge. Delivery is not guaranteed by iOS.
    func updateTrialReminder(access: ActiveAccess?, nextPrice: String?) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.trialReminderID])
        guard settings.trialReminderEnabled, let access, !access.isLifetime, access.willAutoRenew == true,
              access.phase == .introductoryTrial || access.phase == .offerFreePeriod,
              let end = access.expirationDate
        else { return }
        guard let fireDate = Self.reminderDate(periodEnd: end, periodIsLong: access.phase == .offerFreePeriod), fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("notification.trial.title")
        let dateText = end.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(L10n.locale))
        if let nextPrice {
            content.body = L10n.tr("notification.trial.body.price", dateText, nextPrice)
        } else {
            content.body = L10n.tr("notification.trial.body", dateText)
        }
        content.userInfo = ["destination": NotificationDestination.remotePro.rawValue]
        // A time interval (not calendar components): the reminder stays tied to the real period
        // end even if the user travels to another time zone.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fireDate.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.trialReminderID, content: content, trigger: trigger))
    }

    nonisolated static func reminderDate(periodEnd: Date, periodIsLong: Bool) -> Date? {
        periodEnd.addingTimeInterval(periodIsLong ? -48 * 3600 : -36 * 3600)
    }

    // MARK: Remote categories (FCM)

    /// Every topic the app can ever subscribe to. Unsubscribing works from this full set, not from
    /// memory, so a withdrawal also removes topics of another language or an earlier launch.
    static func allTopics(languages: [String] = ["en", "es", "ru", "de", "fr"]) -> Set<String> {
        Set(languages.flatMap { ["service-\($0)", "offers-\($0)"] })
    }

    private var applyChain: Task<Void, Never>?
    /// Last Firebase Installation ID from the Messaging delegate (not our own install ID).
    private var fcmInstallationID: String?

    /// Applies category toggles: FCM registration and topic subscriptions. The local choice is
    /// already saved; failures are shown and retried, never mistaken for an iOS denial.
    /// Calls run one after another so interleaved toggles/retries can't lose a change.
    func applyRemotePreferences() async {
        let previous = applyChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performApplyRemotePreferences()
        }
        applyChain = task
        await task.value
    }

    private func performApplyRemotePreferences() async {
        let wantsService = settings.serviceNotificationsEnabled
        let wantsMarketing = settings.marketingNotificationsConsent.isGranted
        guard remoteCategoriesAvailable else {
            syncState = (wantsService || wantsMarketing) ? .notConfigured : .idle
            return
        }
        #if canImport(FirebaseMessaging)
        let messaging = Messaging.messaging()
        syncState = .syncing
        do {
            if wantsService || wantsMarketing {
                UIApplication.shared.registerForRemoteNotifications()
                messaging.isAutoInitEnabled = true
                let language = L10n.languageCode
                var desired: Set<String> = []
                if wantsService { desired.insert("service-\(language)") }
                if wantsMarketing { desired.insert("offers-\(language)") }
                // Withdrawals first: every topic that is not wanted, whatever was subscribed before.
                for topic in Self.allTopics().subtracting(desired).sorted() { try await messaging.unsubscribe(fromTopic: topic) }
                for topic in desired.sorted() { try await messaging.subscribe(toTopic: topic) }
                subscribedTopics = desired
                // Firebase 12: FCM targets the Firebase Installation ID; the delegate receives it.
                try await messaging.register()
                // Consents changed: update the server record (if the FCM ID isn't known yet, the
                // registration delegate sends it when it arrives).
                if let fcmInstallationID, !(await registerWithServer(token: fcmInstallationID, deleting: false)) {
                    throw URLError(.cannotConnectToHost)
                }
            } else {
                for topic in Self.allTopics().sorted() { try await messaging.unsubscribe(fromTopic: topic) }
                subscribedTopics = []
                messaging.isAutoInitEnabled = false
                try await messaging.unregister()
                fcmTokenAvailable = false
                if !(await registerWithServer(token: nil, deleting: true)) {
                    throw URLError(.cannotConnectToHost)
                }
            }
            syncState = (wantsService || wantsMarketing) ? .synced : .idle
            UserDefaults.standard.set(false, forKey: Self.pendingSyncKey)
        } catch {
            syncState = RemoteSyncState.after(error)
            UserDefaults.standard.set(true, forKey: Self.pendingSyncKey)
        }
        #endif
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        guard FirebaseBootstrap.isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
        DiagnosticsLog.shared.record(.remoteNotificationRegistered)
        #endif
    }

    /// Sends token + consents to the owner's registration endpoint, if one is configured.
    /// Without an endpoint only topic-based delivery works (documented in NOTIFICATIONS.md).
    /// Returns false when the server didn't accept it (the caller keeps the retry flag).
    @discardableResult
    private func registerWithServer(token: String?, deleting: Bool = false) async -> Bool {
        guard let url = configuration.registrationURL else { return true }
        let installationID = Self.installationID()
        let body: [String: Any] = [
            "installationId": installationID,
            "fcmInstallationId": token ?? NSNull(),
            "language": L10n.languageCode,
            "timeZone": TimeZone.current.identifier,
            "categories": ["service": settings.serviceNotificationsEnabled, "offers": settings.marketingNotificationsConsent.isGranted],
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = deleting ? "DELETE" : "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return false }
        return true
    }

    /// Random per-install identifier (not derived from hardware). Deleted with the app.
    static func installationID() -> String {
        let key = "notifications.installationID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: Opening

    func consumeDestination() -> NotificationDestination? {
        defer { pendingDestination = nil }
        return pendingDestination
    }

    fileprivate func handleOpen(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["destination"] as? String, let destination = NotificationDestination(rawValue: raw) else { return }
        // Marketing destinations are dropped if the user withdrew consent meanwhile.
        if destination == .offers, !settings.marketingNotificationsConsent.isGranted { return }
        pendingDestination = destination
        destinationSignal += 1
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // An offer that arrives after consent was withdrawn (topic removal is eventual) is not shown.
        let destination = notification.request.content.userInfo["destination"] as? String
        if destination == NotificationDestination.offers.rawValue {
            let consented = await MainActor.run { self.settings.marketingNotificationsConsent.isGranted }
            if !consented { return [] }
        }
        return [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let destination = info["destination"] as? String
        await MainActor.run { self.handleOpen(userInfo: ["destination": destination as Any]) }
    }
}

#if canImport(FirebaseMessaging)
extension NotificationService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistration installationId: String?) {
        Task { @MainActor in
            self.fcmTokenAvailable = installationId != nil
            self.fcmInstallationID = installationId
            if installationId != nil, self.settings.serviceNotificationsEnabled || self.settings.marketingNotificationsConsent.isGranted {
                await self.registerWithServer(token: installationId)
            }
        }
    }

    nonisolated func messaging(_ messaging: Messaging, didUnregister installationId: String) {
        Task { @MainActor in self.fcmTokenAvailable = false }
    }
}
#endif
