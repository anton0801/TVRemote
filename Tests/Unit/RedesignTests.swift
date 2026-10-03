import UserNotifications
import XCTest
@testable import TVRemoteScreenMirroring

final class NotificationStateTests: XCTestCase {
    func testPermissionMapping() {
        XCTAssertEqual(NotificationPermission(.notDetermined), .notAsked)
        XCTAssertEqual(NotificationPermission(.authorized), .allowed)
        XCTAssertEqual(NotificationPermission(.provisional), .provisional)
        XCTAssertEqual(NotificationPermission(.ephemeral), .provisional)
        XCTAssertEqual(NotificationPermission(.denied), .denied)
        XCTAssertFalse(NotificationPermission.denied.allowsToggling, "Denied → show the Settings card instead")
        XCTAssertTrue(NotificationPermission.notAsked.allowsToggling, "Not asked must not be a dead switch")
    }

    func testSyncErrorsAreNotPermissionErrors() {
        XCTAssertEqual(RemoteSyncState.after(URLError(.notConnectedToInternet)), .pending)
        XCTAssertEqual(RemoteSyncState.after(NSError(domain: "com.google.fcm", code: 3)), .failed)
    }

    @MainActor
    func testWithdrawingConsentIsSavedImmediately() async {
        let defaults = UserDefaults(suiteName: "tests.notifications.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.marketingNotificationsConsent = .granted
        settings.serviceNotificationsEnabled = true
        let service = NotificationService(settings: settings, configuration: .init(registrationURL: nil),
                                          analytics: AnalyticsService(provider: LocalDebugAnalyticsProvider()))
        let stored = await service.setCategory(.offers, enabled: false)
        XCTAssertFalse(stored)
        XCTAssertEqual(settings.marketingNotificationsConsent, .denied)
        XCTAssertEqual(AppSettings(defaults: defaults).marketingNotificationsConsent, .denied, "Persisted, not only in memory")
        // Without a push configuration the remaining category is saved, and the UI says delivery isn't set up.
        // (With a real GoogleService-Info.plist the simulator can't register for FCM, so the
        // delivery state is environment-specific; the saved choice above is what matters.)
        if !FirebaseBootstrap.isConfigured {
            XCTAssertEqual(service.syncState, .notConfigured)
        }
        await service.setCategory(.service, enabled: false)
        XCTAssertFalse(settings.serviceNotificationsEnabled)
        if !FirebaseBootstrap.isConfigured {
            XCTAssertEqual(service.syncState, .idle)
        }
    }
}

@MainActor
final class PaywallRoutingTests: XCTestCase {
    private func presenter(_ state: @escaping () -> AccessState) -> PaywallPresenter {
        PaywallPresenter(accessState: state, analytics: AnalyticsService(provider: LocalDebugAnalyticsProvider()))
    }

    func testOfferAfterCompatibilityCheckOnlyOnceAndOnlyWithoutAccess() async throws {
        let defaults = UserDefaults(suiteName: "tests.paywall.\(UUID().uuidString)")!
        var state: AccessState = .verifying
        let paywall = presenter { state }
        XCTAssertFalse(paywall.offerAfterCompatibilityCheck(deviceID: nil, defaults: defaults), "Never while a purchase may be verifying")
        state = .inactive(.neverPurchased)
        XCTAssertTrue(paywall.offerAfterCompatibilityCheck(deviceID: nil, defaults: defaults))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(paywall.request?.context, .remote)
        paywall.dismiss()
        XCTAssertFalse(paywall.offerAfterCompatibilityCheck(deviceID: nil, defaults: defaults), "Offered once")
    }

    func testNoOfferForPayingUsers() {
        let defaults = UserDefaults(suiteName: "tests.paywall.\(UUID().uuidString)")!
        let paywall = presenter {
            .active(ActiveAccess(plan: .lifetime, productID: "l", phase: .standard, offerID: nil, expirationDate: nil, willAutoRenew: nil,
                                 renewalDate: nil, scheduledProductID: nil, inGracePeriod: false, gracePeriodExpirationDate: nil,
                                 transactionID: nil, coexistingSubscription: nil, isFromCache: false))
        }
        XCTAssertFalse(paywall.offerAfterCompatibilityCheck(deviceID: nil, defaults: defaults))
        XCTAssertNil(paywall.request)
    }
}

final class ServiceLogoSourceTests: XCTestCase {
    func testBundledAssetWinsThenTVIconThenName() {
        XCTAssertEqual(ServiceLogoSource.resolve(assetName: "brand-netflix", assetExists: { _ in true }, hasTVIcon: true), .bundled("brand-netflix"))
        XCTAssertEqual(ServiceLogoSource.resolve(assetName: "brand-netflix", assetExists: { _ in false }, hasTVIcon: true), .tvIcon)
        XCTAssertEqual(ServiceLogoSource.resolve(assetName: nil, assetExists: { _ in true }, hasTVIcon: false), .nameOnly)
    }
}

final class IntroLayoutTests: XCTestCase {
    func testIllustrationShrinksOnSmallScreensAndLargeText() {
        let regular = IntroLayout(size: CGSize(width: 393, height: 852), largeText: false)
        let small = IntroLayout(size: CGSize(width: 375, height: 600), largeText: false)
        let large = IntroLayout(size: CGSize(width: 393, height: 852), largeText: true)
        XCTAssertLessThan(small.illustrationHeight / small.size.height, regular.illustrationHeight / regular.size.height)
        XCTAssertLessThan(large.illustrationHeight, regular.illustrationHeight)
        XCTAssertLessThanOrEqual(regular.illustrationHeight, regular.size.height / 2, "Text always keeps at least half the screen")
    }
}

final class SupportFormTests: XCTestCase {
    func testReplyEmailIsOptionalButMustLookLikeAnAddress() {
        XCTAssertTrue(SupportDraft.isPlausibleEmail(""))
        XCTAssertTrue(SupportDraft.isPlausibleEmail("name@example.com"))
        XCTAssertFalse(SupportDraft.isPlausibleEmail("name@"))
        XCTAssertFalse(SupportDraft.isPlausibleEmail("name example.com"))
        XCTAssertFalse(SupportDraft.isPlausibleEmail("a@b@c.com"))
        XCTAssertFalse(SupportDraft.isPlausibleEmail("name@localhost"))
    }

    @MainActor
    func testReplyEmailGoesIntoTheMessageOnlyWhenValid() {
        let service = SupportService(configuration: .fallback)
        service.deleteDraft()
        service.draft.problem = "Buttons lag"
        service.draft.contactEmail = "name@example.com"
        XCTAssertTrue(service.composedBody(diagnostics: nil).contains("name@example.com"))
        service.draft.contactEmail = "broken@"
        XCTAssertFalse(service.composedBody(diagnostics: nil).contains("broken@"))
        service.deleteDraft()
    }
}

final class PaywallLayoutTests: XCTestCase {
    func testHeroStaysInTopThirdAndShrinksOnSmallPhones() {
        let heights: [CGFloat] = [667, 812, 852, 932, 956]
        for height in heights {
            XCTAssertLessThanOrEqual(PaywallLayout.heroHeight(screenHeight: height), height / 3, "\(height)")
        }
        XCTAssertLessThan(PaywallLayout.heroHeight(screenHeight: 667), PaywallLayout.heroHeight(screenHeight: 852))
        XCTAssertLessThanOrEqual(PaywallLayout.heroHeight(screenHeight: 852), PaywallLayout.heroHeight(screenHeight: 932))
    }
}

/// The note under the purchase button stays within two lines at the default text size on the
/// narrowest supported iPhone (SE: 375 pt − 2 × 20 pt margins), in every language.
final class PaywallFinePrintTests: XCTestCase {
    private var savedLanguage = "en"
    private var savedLocale = Locale.current

    override func setUp() {
        savedLanguage = L10n.languageCode
        savedLocale = L10n.locale
    }

    override func tearDown() {
        L10n.configure(languageCode: savedLanguage, locale: savedLocale)
    }

    private func lineCount(_ text: String) -> Int {
        let font = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let rect = (text as NSString).boundingRect(with: CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font], context: nil)
        return Int((rect.height / font.lineHeight).rounded())
    }

    func testNoteFitsTwoLinesInEveryLanguage() {
        let regions = ["en": "en_US", "es": "es_ES", "ru": "ru_RU", "de": "de_DE", "fr": "fr_FR"]
        let firstCharge = Date(timeIntervalSince1970: 1_790_726_400) // late September — long month names
        for (language, localeID) in regions {
            L10n.configure(languageCode: language, locale: Locale(identifier: localeID))
            // Worst case: a long price format ("59,99 US$").
            let yearly = L10n.tr("price.perYear", "59,99 US$"), monthly = L10n.tr("price.perMonth", "8,99 US$")
            let notes = [
                PaywallCopy.note(plan: .yearly, displayPrice: "59,99 US$", pricePerPeriod: yearly, trialText: L10n.tr("period.days", 3), firstCharge: firstCharge),
                PaywallCopy.note(plan: .yearly, displayPrice: "59,99 US$", pricePerPeriod: yearly, trialText: nil, firstCharge: nil),
                PaywallCopy.note(plan: .monthly, displayPrice: "8,99 US$", pricePerPeriod: monthly, trialText: nil, firstCharge: nil),
                PaywallCopy.note(plan: .lifetime, displayPrice: "199,00 US$", pricePerPeriod: "", trialText: nil, firstCharge: nil),
            ]
            for note in notes {
                XCTAssertLessThanOrEqual(lineCount(note), 2, "[\(language)] \(note)")
                XCTAssertFalse(note.contains(".."), "[\(language)] double period: \(note)")
            }
            XCTAssertTrue(notes[0].contains(PaywallCopy.chargeDateText(firstCharge)), "[\(language)] first charge date is shown")
        }
    }
}

// MARK: - Fixes from the code review (Documentation/REVIEW.md)

final class ReviewFixTests: XCTestCase {
    private func subscription(plan: PurchasePlan = .monthly, expires: Date?, phase: AccessPhase = .standard,
                              willAutoRenew: Bool? = true, coexisting: SubscriptionSummary? = nil) -> ActiveAccess {
        ActiveAccess(plan: plan, productID: plan == .lifetime ? "l" : (plan == .yearly ? "y" : "m"), phase: phase, offerID: nil,
                     expirationDate: expires, willAutoRenew: willAutoRenew, renewalDate: expires, scheduledProductID: nil,
                     inGracePeriod: false, gracePeriodExpirationDate: nil, transactionID: 1,
                     coexistingSubscription: coexisting, isFromCache: false)
    }

    // P3: a stale cache at launch means "don't know yet", never "expired".
    @MainActor
    func testLaunchWithStaleCacheIsVerifyingNotExpired() {
        let now = Date()
        let stale = subscription(expires: now.addingTimeInterval(-3 * 24 * 3600))
        XCTAssertEqual(EntitlementService.launchState(cached: stale, now: now), .verifying)
        XCTAssertEqual(EntitlementResolver.resolveFromCache(stale, now: now), .inactive(.expired), "The offline rule itself is unchanged")
        let fresh = subscription(expires: now.addingTimeInterval(3600))
        XCTAssertEqual(EntitlementService.launchState(cached: fresh, now: now).activeAccess?.plan, .monthly)
        XCTAssertEqual(EntitlementService.launchState(cached: nil, now: now), .verifying)
    }

    // P11: a failed status lookup must not wipe renewal details (and the trial reminder).
    func testMergeKeepsVerifiedRenewalDetails() {
        let cached = subscription(plan: .yearly, expires: Date().addingTimeInterval(2 * 24 * 3600), phase: .introductoryTrial, willAutoRenew: true)
        var fresh = cached
        fresh.willAutoRenew = nil
        fresh.renewalDate = nil
        fresh.phase = .standard
        let merged = EntitlementResolver.merge(fresh, withCached: cached)
        XCTAssertEqual(merged.willAutoRenew, true)
        XCTAssertEqual(merged.renewalDate, cached.renewalDate)
        XCTAssertEqual(merged.phase, .introductoryTrial)
    }

    // P5: lifetime bought during a free trial — the trial will still charge, so it keeps its reminder.
    @MainActor
    func testTrialReminderFollowsOldTrialOfLifetimeOwner() {
        let end = Date().addingTimeInterval(2 * 24 * 3600)
        let trial = SubscriptionSummary(plan: .yearly, productID: "y", willAutoRenew: true, expirationDate: end, phase: .introductoryTrial)
        let lifetime = subscription(plan: .lifetime, expires: nil, willAutoRenew: nil, coexisting: trial)
        let reminded = AppModel.trialReminderAccess(lifetime)
        XCTAssertEqual(reminded?.plan, .yearly)
        XCTAssertEqual(reminded?.phase, .introductoryTrial)
        XCTAssertEqual(reminded?.expirationDate, end)

        let plainLifetime = subscription(plan: .lifetime, expires: nil, willAutoRenew: nil)
        XCTAssertNil(AppModel.trialReminderAccess(plainLifetime), "Nothing will be charged: no reminder")
        let cancelled = SubscriptionSummary(plan: .yearly, productID: "y", willAutoRenew: false, expirationDate: end, phase: .introductoryTrial)
        XCTAssertNil(AppModel.trialReminderAccess(subscription(plan: .lifetime, expires: nil, willAutoRenew: nil, coexisting: cancelled)))
    }

    // P5: a failed renewal Apple still retries is shown next to a new lifetime purchase.
    func testLifetimeOverBillingRetryReportsTheRetryingSubscription() {
        let products = AppConfiguration.Products(monthly: "m", yearly: "y", lifetime: "l", subscriptionGroupID: nil)
        let lifetime = TransactionFact(id: 9, originalID: 9, productID: "l", purchaseDate: .now, expirationDate: nil,
                                       revocationDate: nil, isUpgraded: false, offerKind: nil, offerPayment: nil, offerID: nil)
        let retry = SubscriptionStatusFact(state: .inBillingRetryPeriod, currentProductID: "m", willAutoRenew: true, autoRenewPreference: "m",
                                           renewalDate: nil, gracePeriodExpirationDate: nil, expirationDate: .now, transactionOriginalID: 5)
        let state = EntitlementResolver.resolve(entitlements: [lifetime], statuses: [retry], products: products)
        XCTAssertEqual(state.activeAccess?.plan, .lifetime)
        XCTAssertEqual(state.activeAccess?.coexistingSubscription?.inBillingRetry, true)
        XCTAssertEqual(state.activeAccess?.coexistingSubscription?.willAutoRenew, true)
    }

    // P1: repeated short sessions add up; the free mirroring check always runs out.
    @MainActor
    func testFreeMirroringTimeAccumulatesAcrossSessions() {
        let file = "tests-allowance-\(UUID().uuidString).json"
        let store = DiagnosticAllowanceStore(limits: .init(remoteSeconds: 120, photoShows: 1, mirroringSeconds: 60), fileName: file)
        defer { JSONFileStore<Int>(fileName: file).remove() }
        let tv = TVDeviceID(platform: .lgWebOS, uniqueID: "tv")
        var remaining: [Double] = []
        for _ in 0..<4 {
            // Each session starts from what was used before (as MirroringController does).
            let base = store.usage(for: tv).mirroringSeconds
            store.setMirroringUsed(base + 20, for: tv)
            remaining.append(store.remaining(.mirroring, for: tv))
        }
        XCTAssertEqual(remaining, [40, 20, 0, 0])
        XCTAssertTrue(store.isExhausted(.mirroring, for: tv))
    }
}

@MainActor
final class ReviewPresentationTests: XCTestCase {
    // P4 / N15: no offer while a purchase is being verified; a second request during preparation is ignored.
    func testPaywallNotPresentedWhileVerifyingAndOnlyOnce() async throws {
        var state: AccessState = .verifying
        let presenter = PaywallPresenter(accessState: { state }, analytics: AnalyticsService(provider: LocalDebugAnalyticsProvider()))
        presenter.present(.remote)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(presenter.request, "A paying user may be behind 'verifying'")

        state = .inactive(.neverPurchased)
        var preparations = 0
        presenter.prepareForPresentation = { _ in
            preparations += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        presenter.present(.remote)
        presenter.present(.mirroring) // e.g. a second gated tap while mirroring is stopping
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(presenter.request?.context, .remote)
    }
}

final class ReviewStorageTests: XCTestCase {
    // S13: an unreadable file is kept aside instead of being silently overwritten.
    func testCorruptFileIsPreserved() throws {
        let store = JSONFileStore<[String: Int]>(fileName: "tests-corrupt-\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
        let backup = store.url.appendingPathExtension("unreadable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try? FileManager.default.removeItem(at: backup)
    }

    // S1: withdrawal unsubscribes from every language's topics, not only the current one.
    @MainActor
    func testTopicSetCoversEveryLanguage() {
        let topics = NotificationService.allTopics()
        for language in ["en", "es", "ru", "de", "fr"] {
            XCTAssertTrue(topics.contains("offers-\(language)"))
            XCTAssertTrue(topics.contains("service-\(language)"))
        }
    }

    // S3 / S9: old error context doesn't leak; unchanged or empty drafts aren't rewritten.
    @MainActor
    func testSupportDraftContextAndSaving() {
        let service = SupportService(configuration: .fallback)
        service.deleteDraft()
        service.start(category: .cannotConnect, errorCode: "NET-001", feature: "remote")
        XCTAssertEqual(service.draft.contextErrorCode, "NET-001")
        service.start(category: nil, errorCode: nil, feature: nil)
        XCTAssertNil(service.draft.contextErrorCode, "Opening support from Settings starts without the old error")
        let file = JSONFileStore<SupportDraft>(fileName: "support-draft.json")
        XCTAssertNil(file.load(), "No user text yet: nothing written")

        service.draft.problem = "Buttons lag"
        service.saveDraft(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(file.load()?.updatedAt, Date(timeIntervalSince1970: 1_000))
        service.saveDraft(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(file.load()?.updatedAt, Date(timeIntervalSince1970: 1_000), "Unchanged text keeps its age, so it still expires")
        service.deleteDraft()
    }
}
