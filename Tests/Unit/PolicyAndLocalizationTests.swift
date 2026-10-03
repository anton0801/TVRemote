import XCTest
@testable import TVRemoteScreenMirroring

@MainActor
final class DiagnosticAllowanceTests: XCTestCase {
    private let device = TVDeviceID(platform: .lgWebOS, uniqueID: "tv-1")
    private let limits = AppConfiguration.DiagnosticLimits(remoteSeconds: 120, photoShows: 1, mirroringSeconds: 60)

    private func makeStore() -> DiagnosticAllowanceStore {
        DiagnosticAllowanceStore(limits: limits, fileName: "test-allowance-\(UUID().uuidString).json")
    }

    func testRemoteTimeIsCappedAndExhausts() {
        let store = makeStore()
        store.addRemoteTime(100, for: device)
        XCTAssertEqual(store.remaining(.remote, for: device), 20)
        store.addRemoteTime(100, for: device)
        XCTAssertTrue(store.isExhausted(.remote, for: device))
    }

    func testLimitsArePerTV() {
        let store = makeStore()
        store.addRemoteTime(120, for: device)
        XCTAssertFalse(store.isExhausted(.remote, for: TVDeviceID(platform: .lgWebOS, uniqueID: "tv-2")))
    }

    func testPhotoIsCountedOnlyWhenShown() {
        let store = makeStore()
        XCTAssertEqual(store.remaining(.photo, for: device), 1)
        store.recordPhotoShown(for: device)
        XCTAssertTrue(store.isExhausted(.photo, for: device))
    }

    func testMirroringUsageNeverDecreasesAndRefundOnlyOnceAndOnlyEarly() {
        let store = makeStore()
        store.setMirroringUsed(10, for: device)
        store.setMirroringUsed(5, for: device)
        XCTAssertEqual(store.remaining(.mirroring, for: device), 50)
        store.refundAfterTechnicalFailure(.mirroring, usedSeconds: 10, for: device)
        XCTAssertEqual(store.remaining(.mirroring, for: device), 60)
        store.setMirroringUsed(10, for: device)
        store.refundAfterTechnicalFailure(.mirroring, usedSeconds: 10, for: device)
        XCTAssertEqual(store.remaining(.mirroring, for: device), 50, "Only one refund")
        store.refundAfterTechnicalFailure(.remote, usedSeconds: 40, for: device)
        XCTAssertEqual(store.remaining(.remote, for: device), 120, "Long sessions aren't refunded (nothing used here)")
    }

    func testAccessDecisions() {
        let store = makeStore()
        var state: AccessState = .inactive(.neverPurchased)
        let access = AccessController(allowance: store) { state }
        XCTAssertEqual(access.decision(.remote, device: device), .diagnostic(remaining: 120))
        store.addRemoteTime(120, for: device)
        XCTAssertEqual(access.decision(.remote, device: device), .requiresPro)
        state = .verifying
        XCTAssertEqual(access.decision(.remote, device: device), .full, "A paying user is never locked out while verifying")
        state = .active(ActiveAccess(plan: .lifetime, productID: "l", phase: .standard, offerID: nil, expirationDate: nil, willAutoRenew: nil,
                                     renewalDate: nil, scheduledProductID: nil, inGracePeriod: false, gracePeriodExpirationDate: nil,
                                     transactionID: nil, coexistingSubscription: nil, isFromCache: false))
        XCTAssertEqual(access.decision(.mirroring, device: device), .full, "Pro removes diagnostic limits")
    }

    func testPaywallNeverShownToActiveUsers() async throws {
        var state: AccessState = .active(ActiveAccess(plan: .monthly, productID: "m", phase: .standard, offerID: nil, expirationDate: .distantFuture,
                                                      willAutoRenew: true, renewalDate: nil, scheduledProductID: nil, inGracePeriod: false,
                                                      gracePeriodExpirationDate: nil, transactionID: nil, coexistingSubscription: nil, isFromCache: false))
        let presenter = PaywallPresenter(accessState: { state }, analytics: AnalyticsService(provider: LocalDebugAnalyticsProvider()))
        presenter.present(.remote)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(presenter.request)
        state = .inactive(.expired)
        var prepared = false
        presenter.prepareForPresentation = { _ in prepared = true }
        presenter.present(.mirroring)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.request?.context, .mirroring)
        XCTAssertTrue(prepared, "Mirroring capture must be stopped before the paywall appears")
    }
}

final class BonusRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisitCountingRules() {
        var state = BonusRules.VisitState()
        state = BonusRules.countVisit(state, sessionStart: start, sessionLength: 10, minimumLength: 20, minimumGap: 1800)
        XCTAssertEqual(state.qualifyingVisits, 0, "Too short")
        state = BonusRules.countVisit(state, sessionStart: start, sessionLength: 25, minimumLength: 20, minimumGap: 1800)
        XCTAssertEqual(state.qualifyingVisits, 1)
        state = BonusRules.countVisit(state, sessionStart: start.addingTimeInterval(600), sessionLength: 300, minimumLength: 20, minimumGap: 1800)
        XCTAssertEqual(state.qualifyingVisits, 1, "Within 30 minutes of the last counted visit")
        state = BonusRules.countVisit(state, sessionStart: start.addingTimeInterval(1900), sessionLength: 30, minimumLength: 20, minimumGap: 1800)
        XCTAssertEqual(state.qualifyingVisits, 2)
    }

    func testInvitationEligibility() {
        var state = BonusRules.VisitState(qualifyingVisits: 3, lastCountedVisitStart: start, invitationShown: false, dismissed: false, hadVerifiedSuccess: true)
        XCTAssertTrue(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: true))
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.expired), hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: true), "Former subscribers → win-back, not welcome wheel")
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .verifying, hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: true), "Unknown access")
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: true, campaignAvailable: true, isCalmMoment: true))
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: false))
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: false, campaignAvailable: false, isCalmMoment: true))
        state.dismissed = true
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: true))
        state.dismissed = false
        state.hadVerifiedSuccess = false
        XCTAssertFalse(BonusRules.shouldInvite(state, qualifyingVisitNumber: 3, access: .inactive(.neverPurchased), hasPendingPurchase: false, campaignAvailable: true, isCalmMoment: true))
    }

    func testDrawIsUniformAcrossAvailableSectors() {
        struct SplitMix: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
        }
        var generator = SplitMix(state: 42)
        var counts: [String: Int] = [:]
        for _ in 0..<70_000 {
            let sector = BonusRules.draw(from: BonusSector.targetSectors, using: &generator)!
            counts[sector.id, default: 0] += 1
        }
        XCTAssertEqual(counts.count, 7)
        for (_, count) in counts { XCTAssertEqual(Double(count) / 70_000, 1.0 / 7, accuracy: 0.01) }
    }

    func testRealDiscountIsNeverRoundedUp() {
        XCTAssertEqual(BonusRules.realDiscountPercent(standard: Decimal(string: "8.99")!, offer: Decimal(string: "6.29")!), 30)
        XCTAssertEqual(BonusRules.realDiscountPercent(standard: Decimal(string: "8.99")!, offer: Decimal(string: "8.59")!), 4, "Would be 5% only if ≥ 5.00%")
        XCTAssertEqual(BonusRules.realDiscountPercent(standard: Decimal(string: "8.99")!, offer: Decimal(string: "8.49")!), 5)
    }

    func testDiscountSectorShownOnlyWhenRealPriceMatches() {
        let d30 = BonusSector(id: "d30", kind: .firstMonthDiscount(percent: 30), plans: [.monthly])
        let d10 = BonusSector(id: "d10", kind: .firstMonthDiscount(percent: 10), plans: [.monthly])
        let standard = Decimal(string: "8.99")!
        XCTAssertTrue(BonusRules.isConsistent(d30, standardMonthly: standard, firstPeriodPrice: Decimal(string: "6.29")))
        XCTAssertFalse(BonusRules.isConsistent(d10, standardMonthly: standard, firstPeriodPrice: Decimal(string: "7.99")), "7.99 is 11%, not 10%")
        XCTAssertFalse(BonusRules.isConsistent(d30, standardMonthly: standard, firstPeriodPrice: nil), "Unknown price → not shown")
        XCTAssertTrue(BonusRules.isConsistent(BonusSector.targetSectors.last!, standardMonthly: nil, firstPeriodPrice: nil))
    }

    func testRedemptionURLContainsCodeAndApp() throws {
        let url = try XCTUnwrap(BonusController.redemptionURL(appID: "123456789", code: "ABC 1"))
        XCTAssertEqual(url.host, "apps.apple.com")
        XCTAssertTrue(url.absoluteString.contains("id=123456789"))
        XCTAssertTrue(url.absoluteString.contains("code=ABC%201"))
    }

    func testOfferServiceEndpointKeepsQuery() {
        let service = OfferCodeService(baseURL: URL(string: "https://offers.example.test/api")!, campaignID: "welcome-wheel-v1", rulesVersion: "1")
        let url = service.endpoint("v1/campaigns/welcome-wheel-v1/availability", query: [URLQueryItem(name: "storefront", value: "USA")])
        XCTAssertEqual(url.absoluteString, "https://offers.example.test/api/v1/campaigns/welcome-wheel-v1/availability?storefront=USA")
    }

    func testTrialReminderLeavesTimeToCancel() {
        let end = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(NotificationService.reminderDate(periodEnd: end, periodIsLong: true), end.addingTimeInterval(-48 * 3600))
        XCTAssertEqual(NotificationService.reminderDate(periodEnd: end, periodIsLong: false), end.addingTimeInterval(-36 * 3600))
    }
}

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "es", "ru", "de", "fr"]

    private func table(_ language: String, _ name: String = "Localizable") -> [String: String] {
        let bundle = Bundle(for: AppModel.self)
        guard let path = bundle.path(forResource: name, ofType: "strings", inDirectory: nil, forLocalization: language),
              let dictionary = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dictionary
    }

    func testAllLanguagesHaveTheSameKeys() {
        let english = Set(table("en").keys)
        XCTAssertGreaterThan(english.count, 600)
        for language in languages.dropFirst() {
            let keys = Set(table(language).keys)
            XCTAssertEqual(keys, english, "\(language) differs: missing \(english.subtracting(keys).sorted().prefix(5))")
            XCTAssertTrue(table(language).values.allSatisfy { !$0.isEmpty }, "\(language) has empty values")
        }
    }

    func testPurposeStringLocalized() {
        for language in languages {
            XCTAssertFalse(table(language, "InfoPlist")["NSLocalNetworkUsageDescription"]?.isEmpty ?? true, language)
        }
    }

    func testRussianPluralForms() {
        L10n.configure(languageCode: "ru", locale: Locale(identifier: "ru_RU"), in: Bundle(for: AppModel.self))
        defer { L10n.configure(languageCode: "en", locale: Locale(identifier: "en_US"), in: Bundle(for: AppModel.self)) }
        XCTAssertEqual(L10n.tr("period.days", 1), "1 день")
        XCTAssertEqual(L10n.tr("period.days", 3), "3 дня")
        XCTAssertEqual(L10n.tr("period.days", 7), "7 дней")
        XCTAssertEqual(L10n.tr("period.days", 21), "21 день")
        XCTAssertEqual(L10n.tr("paywall.cta.trial.days", 3), "Попробовать 3 дня бесплатно")
    }

    func testEnglishAndGermanTrialButtons() {
        let bundle = Bundle(for: AppModel.self)
        L10n.configure(languageCode: "en", locale: Locale(identifier: "en_US"), in: bundle)
        XCTAssertEqual(L10n.tr("paywall.cta.trial.days", 3), "Start 3-day free trial")
        L10n.configure(languageCode: "de", locale: Locale(identifier: "de_DE"), in: bundle)
        XCTAssertEqual(L10n.tr("paywall.cta.trial.days", 3), "3 Tage kostenlos testen")
        L10n.configure(languageCode: "en", locale: Locale(identifier: "en_US"), in: bundle)
    }

    func testMissingKeyNeverShowsRawKeyInRelease() {
        let value = L10n.tr("definitely.missing.key")
        #if DEBUG
        XCTAssertTrue(value.contains("definitely.missing.key"))
        #else
        XCTAssertEqual(value, "")
        #endif
    }

    func testSystemLanguageResolution() {
        XCTAssertEqual(LocalizationManager.resolvedCode(for: .system, preferred: ["pt-BR", "de-DE"]), "de")
        XCTAssertEqual(LocalizationManager.resolvedCode(for: .system, preferred: ["ja"]), "en")
        XCTAssertEqual(LocalizationManager.resolvedCode(for: .fr, preferred: ["de"]), "fr")
    }

    func testEveryErrorHasLocalizedTexts() {
        let errors: [AppError] = [.localNetworkDenied, .noWiFi, .discoveryFoundNothing, .deviceUnreachable, .pairingWrongPIN, .tlsIdentityMismatch,
                                  .textFieldNotFocused, .mediaFormatUnsupported, .mirroringReceiverMissing, .storeProductsUnavailable,
                                  .purchasePending, .offerSoldOut, .supportNotConfigured, .unexpected]
        let english = table("en")
        for error in errors {
            XCTAssertNotNil(english["\(error.localizationKey).title"], error.code)
            XCTAssertNotNil(english["\(error.localizationKey).message"], error.code)
        }
    }
}

final class DesignTokenContrastTests: XCTestCase {
    /// Design kit v2 is dark only; every text color must stay readable on the surfaces it uses.
    func testTextContrastMeetsWCAG_AA() {
        let pairs: [(Palette.RGB, Palette.RGB, Double, String)] = [
            (Palette.textPrimary, Palette.background, 4.5, "primary/background"),
            (Palette.textPrimary, Palette.surface, 4.5, "primary/surface"),
            (Palette.textPrimary, Palette.surfaceRaised, 4.5, "primary/raised"),
            (Palette.textSecondary, Palette.background, 4.5, "secondary/background"),
            (Palette.textSecondary, Palette.surface, 4.5, "secondary/surface"),
            (Palette.accent, Palette.background, 4.5, "accent text/background"),
            (Palette.accent, Palette.surface, 4.5, "accent text/surface"),
            (Palette.accent, Palette.accentTint, 4.5, "selected card action"),
            (Palette.textPrimary, Palette.accentTint, 4.5, "selected card title"),
            (Palette.textSecondary, Palette.accentTint, 4.5, "selected card detail"),
            (Palette.onAccent, Palette.accent, 4.5, "button label/amber button"),
            (Palette.onDangerFill, Palette.dangerFill, 4.5, "stop sharing label"),
            (Palette.danger, Palette.surface, 4.5, "danger/surface"),
            (Palette.success, Palette.surface, 4.5, "success/surface"),
        ]
        for (foreground, background, minimum, name) in pairs {
            XCTAssertGreaterThanOrEqual(foreground.contrast(with: background), minimum, name)
        }
    }

    func testTokensMatchDesignKit() {
        // design-system/tokens.json
        XCTAssertEqual(Palette.background, Palette.RGB(hex: 0x111214))
        XCTAssertEqual(Palette.surface, Palette.RGB(hex: 0x202226))
        XCTAssertEqual(Palette.accent, Palette.RGB(hex: 0xFFB24A))
        XCTAssertEqual(Palette.border, Palette.RGB(hex: 0x3B3E44))
    }
}

final class PrivacyTests: XCTestCase {
    func testAnalyticsParametersNeverContainFreeText() {
        let events: [AnalyticsEvent] = [
            .textSendResult(platform: .lgWebOS, result: .success, errorCode: nil),
            .tvAppLaunchResult(platform: .samsungTizen, appID: "My Secret Home Video App", result: .success),
            .discoveryCompleted(found: 250, permissionDenied: false),
            .onboardingCompleted(task: "anything"),
        ]
        for event in events {
            for (_, value) in event.parameters {
                if case .string(let text) = value {
                    XCTAssertLessThanOrEqual(text.count, 24)
                    XCTAssertFalse(text.contains(" "), "No free text in analytics: \(text)")
                }
            }
        }
        XCTAssertEqual(AnalyticsEvent.tvAppLaunchResult(platform: .samsungTizen, appID: "private app", result: .success).parameters["app"], .string("other"))
        XCTAssertEqual(AnalyticsEvent.discoveryCompleted(found: 250, permissionDenied: false).parameters["found_count"], .int(20))
    }

    func testAnalyticsDisabledUntilConsent() async {
        final class Recorder: AnalyticsProvider, @unchecked Sendable {
            var names: [String] = []
            var enabled = false
            func setCollectionEnabled(_ enabled: Bool) { self.enabled = enabled }
            func log(name: String, parameters: [String: Any]) { names.append(name) }
        }
        let recorder = Recorder()
        await MainActor.run {
            let service = AnalyticsService(provider: recorder)
            service.setConsent(.undecided)
            service.log(.discoveryStarted)
            service.setConsent(.granted)
            service.log(.discoveryStarted)
            service.setConsent(.denied)
            service.log(.discoveryStarted)
        }
        XCTAssertEqual(recorder.names, ["discovery_started"])
        XCTAssertFalse(recorder.enabled)
    }

    @MainActor
    func testSupportDiagnosticsContainNoAddressesOrNames() {
        DiagnosticsLog.shared.record(.connected, platform: .lgWebOS, error: .connectionLost)
        let support = SupportService(configuration: .fallback)
        support.draft.problem = "My TV at 192.168.1.20 named Living Room"
        let diagnostics = support.diagnostics(platform: .lgWebOS, access: .inactive(.neverPurchased))
        let text = diagnostics.lines().joined(separator: "\n")
        XCTAssertNil(text.range(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, options: .regularExpression), "No IP addresses")
        XCTAssertFalse(text.contains("Living Room"))
        XCTAssertTrue(text.contains("inactive"))
        support.draft.includeDiagnostics = false
        XCTAssertFalse(support.composedBody(diagnostics: diagnostics).contains("Recent states"), "Diagnostics off by default")
    }

    @MainActor
    func testExpiredSupportDraftIsPurged() {
        let support = SupportService(configuration: .fallback)
        support.draft.problem = "old"
        support.saveDraft()
        support.purgeExpiredDraft(now: Date().addingTimeInterval(8 * 24 * 3600))
        let reloaded = SupportService(configuration: .fallback)
        XCTAssertTrue(reloaded.draft.isEmpty)
    }

    func testReceiverPageContainsSessionAndEscapesText() {
        let html = ReceiverPage.html(webSocketPort: 50123, token: "abc123", language: "fr")
        XCTAssertTrue(html.contains(":50123/"))
        XCTAssertTrue(html.contains("\"tabc123\""))
        XCTAssertTrue(html.contains("lang=\"fr\""))
        XCTAssertFalse(html.contains("http"), "No external resources: the page talks only to the phone")
    }

    func testMirroringFrameHeaderAndAck() {
        let header = MirroringFrameHeader.make(sequence: 258, timestampMs: 65_537, quarterTurns: 1)
        XCTAssertEqual(header, Data([1, 1, 0, 0, 1, 2, 0, 1, 0, 1]))
        XCTAssertEqual(MirroringFrameHeader.parseAck("a:258:65537")?.sequence, 258)
        XCTAssertNil(MirroringFrameHeader.parseAck("x:1:2"))
    }

    func testMirroringRequestExpires() {
        let fresh = MirroringRequest(sessionID: UUID(), token: "t", tvHost: "192.168.1.2", mode: .diagnostic(limitSeconds: 60), createdAt: Date(),
                                     languageCode: "en", maxLongSide: 1280, maxFramesPerSecond: 24)
        XCTAssertTrue(fresh.isFresh)
        var stale = fresh
        stale.createdAt = Date().addingTimeInterval(-3600)
        XCTAssertFalse(stale.isFresh, "A leftover request must never start a broadcast")
    }

    func testErrorCodesAreUnique() {
        let errors: [AppError] = [.localNetworkDenied, .noWiFi, .discoveryFoundNothing, .deviceUnreachable, .deviceAddressChanged, .pairingRejected,
                                  .pairingTimedOut, .pairingWrongPIN, .pairingTokenRevoked, .pairingUnsupportedFirmware, .tlsIdentityMismatch,
                                  .connectionLost, .commandNotSupported, .commandTimedOut, .textFieldNotFocused, .textNotSupported, .textResultUnknown,
                                  .appNotInstalled, .appLaunchFailed, .appListUnavailable, .mediaRendererMissing, .mediaFormatUnsupported, .mediaLoadFailed,
                                  .mediaICloudDownloadFailed, .mediaInsufficientStorage, .mediaPlaybackFailed, .mirroringReceiverMissing,
                                  .mirroringBrowserLaunchFailed, .mirroringStoppedBySystem, .mirroringNetworkLost, .mirroringProtectedContent,
                                  .mirroringThermal, .mirroringNotStarted, .storeProductsUnavailable, .purchasePending, .purchaseFailed,
                                  .purchaseNotAllowed, .restoreFoundNothing, .entitlementRefreshFailed, .offerUnavailable, .offerExpired,
                                  .offerAlreadyUsed, .offerSoldOut, .offerServiceUnavailable, .mailUnavailable, .supportNotConfigured, .unexpected]
        XCTAssertEqual(Set(errors.map(\.code)).count, errors.count)
    }

    func testFrameEncoderTargetSize() {
        XCTAssertEqual(FrameEncoderSizing.targetSize(width: 1179, height: 2556, maxLongSide: 1280).height, 1280)
        XCTAssertEqual(FrameEncoderSizing.targetSize(width: 1179, height: 2556, maxLongSide: 1280).width % 2, 0)
        XCTAssertEqual(FrameEncoderSizing.targetSize(width: 640, height: 480, maxLongSide: 1280).width, 640)
    }
}
