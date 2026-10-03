import Foundation
import Observation
import SwiftUI

/// Composition root: creates services once and wires their interactions.
@MainActor
@Observable
final class AppModel {
    enum Tab: Hashable { case remote, cast, settings }

    /// Screens of the Cast tab that other tabs can open (Remote: "Cast photos", "Cast videos").
    enum CastRoute: Hashable { case photos, videos, mirroring }

    enum Sheet: Identifiable, Equatable {
        case discovery
        case compatibility
        case help(HelpArticle.ID?)
        case contactSupport(category: SupportCategory?, errorCode: String?, feature: String?)
        case remotePro
        case bonus
        case introduction
        case purchaseSuccess(PurchasePlan)

        var id: String {
            switch self {
            case .discovery: "discovery"
            case .compatibility: "compatibility"
            case .help(let article): "help-\(article ?? "")"
            case .contactSupport: "support"
            case .remotePro: "remotePro"
            case .bonus: "bonus"
            case .introduction: "introduction"
            case .purchaseSuccess: "purchaseSuccess"
            }
        }
    }

    var selectedTab: Tab = .remote
    var sheet: Sheet?
    /// Pending navigation inside the Cast tab; consumed by `CastScreen`.
    var castRequest: CastRoute?
    private(set) var isActive = false
    /// Screens with their own sheets (Remote: keyboard, all apps, more keys) report them here.
    /// SwiftUI can't show a root-level sheet or cover while such a sheet is up.
    var localSheetOpen = false
    /// Bumped to ask those screens to close their sheets before a root-level presentation.
    private(set) var closeLocalSheetsSignal = 0

    let configuration: AppConfiguration
    let settings: AppSettings
    let localization: LocalizationManager
    let devices: DeviceStore
    let analytics: AnalyticsService
    let crashReporting: CrashReportingService
    let discovery: DiscoveryService
    let connection: ConnectionManager
    let checker: CompatibilityChecker
    let entitlements: EntitlementService
    let store: StoreService
    let allowance: DiagnosticAllowanceStore
    let access: AccessController
    let paywall: PaywallPresenter
    let text: TextInputController
    let apps: TVAppsController
    let iconStore = TVIconStore()
    let media: MediaCastController
    let mirroring: MirroringController
    let notifications: NotificationService
    let support: SupportService
    let bonus: BonusController

    private var usageMeter: Task<Void, Never>?
    private var started = false

    init() {
        FirebaseBootstrap.configureIfAvailable()
        let configuration = AppConfiguration.load()
        self.configuration = configuration
        settings = AppSettings()
        localization = LocalizationManager()
        devices = DeviceStore()
        #if canImport(FirebaseAnalytics)
        let provider: AnalyticsProvider = FirebaseBootstrap.isConfigured ? FirebaseAnalyticsProvider() : LocalDebugAnalyticsProvider()
        #else
        let provider: AnalyticsProvider = LocalDebugAnalyticsProvider()
        #endif
        analytics = AnalyticsService(provider: provider)
        crashReporting = CrashReportingService()
        discovery = DiscoveryService(analytics: analytics)
        connection = ConnectionManager(devices: devices, analytics: analytics)
        checker = CompatibilityChecker(devices: devices, analytics: analytics)
        entitlements = EntitlementService(products: configuration.products, analytics: analytics)
        store = StoreService(configuration: configuration.products, entitlements: entitlements, analytics: analytics)
        allowance = DiagnosticAllowanceStore(limits: configuration.limits)
        access = AccessController(allowance: allowance) { [entitlements] in entitlements.state }
        paywall = PaywallPresenter(accessState: { [entitlements] in entitlements.state }, analytics: analytics)
        text = TextInputController(connection: connection, analytics: analytics)
        apps = TVAppsController(connection: connection, devices: devices, checker: checker, analytics: analytics)
        media = MediaCastController(connection: connection, checker: checker, access: access, paywall: paywall, settings: settings, analytics: analytics)
        mirroring = MirroringController(connection: connection, access: access, paywall: paywall, checker: checker, analytics: analytics)
        notifications = NotificationService(settings: settings, configuration: configuration.notifications, analytics: analytics)
        support = SupportService(configuration: configuration)
        bonus = BonusController(configuration: configuration, entitlements: entitlements, store: store, analytics: analytics)
        wire()
    }

    private func wire() {
        Haptics.isEnabled = settings.hapticsEnabled
        analytics.setConsent(settings.analyticsConsent)
        crashReporting.setConsent(settings.crashReportsConsent)

        connection.onConnected = { [weak self] device, session in
            self?.checker.run(for: device, session: session)
            self?.crashReporting.setSafeKeys(platform: device.platform, entitlement: self?.entitlements.state.supportLabel ?? "unknown")
        }
        connection.onSessionEnded = { [weak self] deviceID, reason in
            guard let self else { return }
            self.text.reset()
            // A dropped control socket doesn't affect DLNA playback or the mirroring link (the
            // TV browser talks to the broadcast extension directly); only a deliberate switch,
            // forget or disconnect stops them.
            guard reason == .replaced else { return }
            if self.media.isBusy { self.media.stop() }
            if self.mirroring.deviceID == deviceID, self.mirroring.isActive {
                Task { await self.mirroring.stop() }
            }
        }
        entitlements.onVerifiedPurchase = { [weak self] plan, phase in
            guard let self else { return }
            self.paywall.completed(with: plan)
            if phase == .introductoryTrial || phase == .offerFreePeriod {
                self.analytics.log(.trialStarted(plan: plan.analyticsPlan))
            }
            self.bonus.handleVerifiedPurchase(plan: plan, phase: phase)
            Task { await self.updateTrialReminder() }
        }
        entitlements.onStateChange = { [weak self] _, newState in
            guard let self else { return }
            // Access confirmed (e.g. verification finished, family purchase): the offer is moot.
            if newState.hasAccess, self.paywall.request != nil, self.store.purchaseInProgress == nil {
                self.paywall.dismiss()
            }
            // Access ended (refund/revocation/expiry) during unlimited mirroring: stop cleanly.
            if !newState.hasAccess, newState != .verifying, self.mirroring.isActive, !self.mirroring.isDiagnostic {
                Task { await self.mirroring.stop() }
            }
            Task { await self.updateTrialReminder() }
        }
        text.isAllowed = { [weak self] in self?.remoteAllowed() ?? false }
        media.onVerifiedUse = { [weak self] in self?.bonus.recordVerifiedSuccess() }
        mirroring.onVerifiedUse = { [weak self] in self?.bonus.recordVerifiedSuccess() }
        paywall.prepareForPresentation = { [weak self] _ in
            guard let self else { return }
            // Never let the purchase sheet appear on the TV.
            if self.mirroring.isCapturing { await self.mirroring.stop() }
            // A full-screen cover can't appear over a sheet: close them first.
            await self.clearForRootPresentation(closingSheet: true)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        MediaWorkspace.clearAll() // crash recovery for temporary cast files
        DiagnosticsLog.shared.record(.appLaunched)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DemoTV") {
            settings.onboardingCompleted = true
            connection.attachDemoTV(devices: devices)
            // UI tests of the "free check used up" paths.
            if ProcessInfo.processInfo.arguments.contains("-DemoFreeCheckUsed") {
                allowance.addRemoteTime(Double(configuration.limits.remoteSeconds), for: DemoTVSession.demoID)
            }
        }
        #endif
        entitlements.start()
        notifications.start()
        Task {
            await store.loadProducts()
            await updateTrialReminder() // the reminder text needs the price
        }
        if settings.onboardingCompleted, devices.selectedDevice != nil {
            connection.resumeIfNeeded()
        }
        startUsageMeter()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            DiagnosticsLog.shared.record(.appForegrounded)
            bonus.appBecameActive()
            if settings.onboardingCompleted { connection.resumeIfNeeded() }
            Task {
                await entitlements.refresh()
                await notifications.refreshAuthorization()
                await notifications.retryPendingSync()
            }
        case .background:
            isActive = false
            DiagnosticsLog.shared.record(.appBackgrounded)
            bonus.appWillResignActive()
            support.saveDraft()
        default:
            isActive = false
        }
    }

    // MARK: Gated actions

    /// Sends a remote command if Remote Pro or the free diagnostic allows it.
    @discardableResult
    func sendCommand(_ command: RemoteCommand, action: KeyAction = .click) -> Bool {
        guard let deviceID = connection.state.deviceID else { return false }
        if action != .release, access.decision(.remote, device: deviceID) == .requiresPro {
            paywall.present(.remote, feature: .remote, deviceID: deviceID)
            return false
        }
        let sent = connection.send(command, action: action)
        if sent { bonus.recordVerifiedSuccess() }
        return sent
    }

    /// True when remote-type features (buttons, keyboard, app shortcuts) are usable now.
    func remoteAllowed() -> Bool {
        guard let deviceID = connection.state.deviceID else { return false }
        if access.decision(.remote, device: deviceID) == .requiresPro {
            paywall.present(.remote, feature: .remote, deviceID: deviceID)
            return false
        }
        return true
    }

    /// Switches to the Cast tab and opens one of its screens.
    func openCast(_ route: CastRoute) {
        castRequest = route
        selectedTab = .cast
    }

    func openSupport(category: SupportCategory? = nil, errorCode: String? = nil, feature: String? = nil) {
        analytics.log(.supportOpened(source: feature ?? "settings"))
        DiagnosticsLog.shared.record(.supportOpened)
        Task {
            // Support must never be shown on the TV.
            if mirroring.isCapturing { await mirroring.stop() }
            sheet = .contactSupport(category: category, errorCode: errorCode, feature: feature)
        }
    }

    /// Opens a root-level sheet. The paywall and any screen-local sheet are closed first
    /// (SwiftUI can't stack them); replacing another root sheet is handled by `sheet(item:)`.
    func present(_ sheet: Sheet) {
        guard paywall.request != nil || localSheetOpen else {
            self.sheet = sheet
            return
        }
        let paywallWasUp = paywall.request != nil
        paywall.dismiss()
        Task {
            await clearForRootPresentation(closingSheet: false)
            if paywallWasUp { try? await Task.sleep(for: .milliseconds(450)) }
            self.sheet = sheet
        }
    }

    /// Asks screens to close their local sheets (and optionally the root sheet), then waits for
    /// the dismissal animation.
    func clearForRootPresentation(closingSheet: Bool) async {
        var waited = false
        if localSheetOpen {
            closeLocalSheetsSignal += 1
            waited = true
        }
        if closingSheet, sheet != nil {
            sheet = nil
            waited = true
        }
        if waited { try? await Task.sleep(for: .milliseconds(500)) }
    }

    /// Screen-local sheets must give way to a root-level prompt (e.g. TV pairing).
    func closeLocalSheets() {
        if localSheetOpen { closeLocalSheetsSignal += 1 }
    }

    /// Nothing the user is in the middle of: safe to show something unasked (a notification's
    /// screen, the bonus invitation).
    var isCalmForUnrequestedPresentation: Bool {
        settings.onboardingCompleted && sheet == nil && !localSheetOpen && paywall.request == nil
            && !mirroring.isActive && connection.pairing.prompt == .none && store.purchaseInProgress == nil
            && text.status != .sending
    }

    /// Opens a tapped notification's screen once the moment is calm; called again whenever a
    /// blocker clears, so a destination is never dropped.
    func routePendingNotification() {
        guard notifications.pendingDestination != nil, isCalmForUnrequestedPresentation else { return }
        switch notifications.consumeDestination() {
        case .offers?:
            if bonus.hasSomethingToShow { sheet = .bonus }
        case .remotePro?: sheet = .remotePro
        case .help?, .serviceUpdate?: sheet = .help(nil)
        case nil: break
        }
    }

    /// Shows a pending bonus invitation in a calm moment (kept for later otherwise).
    func showBonusInvitationIfCalm() {
        guard bonus.invitationPending, isCalmForUnrequestedPresentation, selectedTab == .remote else { return }
        guard bonus.hasSomethingToShow else {
            bonus.invitationPending = false
            return
        }
        sheet = .bonus
    }

    /// In-app language changed: texts built outside the view tree must be rebuilt.
    func languageChanged() {
        Task {
            await updateTrialReminder()
            await notifications.applyRemotePreferences() // topics are per language
        }
    }

    enum ConnectRequest { case alreadyConnected, needsConfirmation, started }

    /// Connect from any list (header, Discovery, Saved TVs). Tapping the TV that is already
    /// connected (or connecting) does nothing; switching while mirroring or casting needs a
    /// confirmation first (`confirmSwitch`).
    @discardableResult
    func requestConnection(to deviceID: TVDeviceID, connect: () -> Void) -> ConnectRequest {
        if connection.state.deviceID == deviceID {
            switch connection.state {
            case .connected, .connecting, .pairing, .reconnecting: return .alreadyConnected
            default: break
            }
        }
        if mirroring.isActive || media.isBusy { return .needsConfirmation }
        connect()
        return .started
    }

    /// The user confirmed switching TVs: stop mirroring / casting first, then connect.
    func confirmSwitch(connect: @escaping @MainActor () -> Void) {
        Task {
            if mirroring.isActive { await mirroring.stop() }
            if media.isBusy { media.stop() }
            connect()
        }
    }

    /// Forget a TV: disconnect, remove its data, credentials and cached icons.
    func forgetTV(_ id: TVDeviceID) {
        connection.forget(id)
        iconStore.clear(device: id)
    }

    func updateTrialReminder() async {
        let access = Self.trialReminderAccess(entitlements.state.activeAccess)
        let price = access.flatMap { store.products[$0.plan].map(PriceFormatter.pricePerPeriodSentence) }
        await notifications.updateTrialReminder(access: access, nextPrice: price)
    }

    /// The access the trial reminder is about. A lifetime owner whose old subscription is still
    /// in a free period will be charged when it ends — that subscription gets the reminder.
    static func trialReminderAccess(_ access: ActiveAccess?) -> ActiveAccess? {
        guard let access, access.isLifetime else { return access }
        guard let old = access.coexistingSubscription, old.willAutoRenew == true,
              let phase = old.phase, phase == .introductoryTrial || phase == .offerFreePeriod else { return nil }
        return ActiveAccess(plan: old.plan, productID: old.productID, phase: phase, offerID: nil,
                            expirationDate: old.expirationDate, willAutoRenew: true, renewalDate: old.expirationDate,
                            scheduledProductID: nil, inGracePeriod: false, gracePeriodExpirationDate: nil,
                            transactionID: nil, coexistingSubscription: nil, isFromCache: access.isFromCache)
    }

    func setAnalyticsConsent(_ consent: ConsentState) {
        settings.analyticsConsent = consent
        analytics.setConsent(consent)
    }

    func setCrashConsent(_ consent: ConsentState) {
        settings.crashReportsConsent = consent
        crashReporting.setConsent(consent)
    }

    /// Counts free remote time only while a real session is live and the app is in front.
    private func startUsageMeter() {
        usageMeter?.cancel()
        usageMeter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // Only time actually spent on the remote counts (not Settings, Cast, Help or the
                // paywall itself).
                guard let self, self.isActive, case .connected(let id) = self.connection.state,
                      self.settings.onboardingCompleted, self.selectedTab == .remote,
                      self.sheet == nil, self.paywall.request == nil,
                      case .diagnostic = self.access.decision(.remote, device: id)
                else { continue }
                self.allowance.addRemoteTime(1, for: id)
                if self.allowance.isExhausted(.remote, for: id) {
                    self.analytics.log(.diagnosticCompleted(feature: .remote, exhausted: true))
                }
            }
        }
    }
}
