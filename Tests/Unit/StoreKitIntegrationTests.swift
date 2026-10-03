import StoreKit
import StoreKitTest
import XCTest
@testable import TVRemoteScreenMirroring

/// Runs against `RemotePro.storekit` in the local StoreKit test environment.
/// These tests prove the client logic with Apple's test harness; they are NOT Sandbox or
/// production verification (see TESTING.md).
@MainActor
final class StoreKitIntegrationTests: XCTestCase {
    private var session: SKTestSession!
    private let products = AppConfiguration.Products(monthly: "remote_pro_monthly", yearly: "remote_pro_yearly", lifetime: "remote_pro_lifetime", subscriptionGroupID: nil)
    private var entitlements: EntitlementService!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "RemotePro")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.storefront = "USA"
        let service = "tests.entitlement.\(UUID().uuidString)"
        entitlements = EntitlementService(products: products, analytics: AnalyticsService(provider: LocalDebugAnalyticsProvider()), cacheService: service)
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        entitlements = nil
    }

    private func loadProducts() async throws -> [String: Product] {
        let loaded = try await Product.products(for: products.all)
        return Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    }

    // Scenario: approved prices and product types.
    func testProductsMatchApprovedPricing() async throws {
        let map = try await loadProducts()
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map[products.monthly]?.price, Decimal(string: "8.99"))
        XCTAssertEqual(map[products.yearly]?.price, Decimal(string: "59.99"))
        XCTAssertEqual(map[products.lifetime]?.price, Decimal(string: "199.00"))
        XCTAssertEqual(map[products.lifetime]?.type, .nonConsumable)
        XCTAssertEqual(map[products.monthly]?.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(map[products.yearly]?.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(map[products.monthly]?.subscription?.subscriptionGroupID, map[products.yearly]?.subscription?.subscriptionGroupID)
    }

    // Scenarios 1–3: 3-day trial on yearly only; monthly promises no trial.
    // Named to run first: StoreKit caches intro eligibility per process, and later tests buy
    // subscriptions in the same group (one intro offer per group per customer).
    func testA_NewUserGetsThreeDayTrialOnYearlyOnly() async throws {
        let map = try await loadProducts()
        let intro = try XCTUnwrap(map[products.yearly]?.subscription?.introductoryOffer)
        XCTAssertEqual(intro.paymentMode, .freeTrial)
        XCTAssertEqual(intro.period.unit, .day)
        XCTAssertEqual(intro.period.value, 3)
        XCTAssertNil(map[products.monthly]?.subscription?.introductoryOffer)
        let eligible = await map[products.yearly]!.subscription!.isEligibleForIntroOffer
        XCTAssertTrue(eligible)
    }

    func testTrialPurchaseGrantsAccessAndConsumesEligibility() async throws {
        _ = try await session.buyProduct(identifier: products.yearly)
        await entitlements.refresh()
        XCTAssertEqual(entitlements.state.activeAccess?.plan, .yearly)
        XCTAssertEqual(entitlements.state.activeAccess?.phase, .introductoryTrial)
        let map = try await loadProducts()
        let eligible = await map[products.yearly]!.subscription!.isEligibleForIntroOffer
        XCTAssertFalse(eligible, "No second trial in the same subscription group")
    }

    // Paywall: CTA and billing note follow the selected plan and use StoreKit prices.
    func testPaywallCopyFollowsSelectedPlan() async throws {
        let map = try await loadProducts()
        let yearly = try XCTUnwrap(map[products.yearly]), monthly = try XCTUnwrap(map[products.monthly]), lifetime = try XCTUnwrap(map[products.lifetime])
        let trial = try XCTUnwrap(yearly.subscription?.introductoryOffer?.period)
        let titles = [
            PaywallCopy.ctaTitle(plan: .yearly, product: yearly, trialPeriod: trial),
            PaywallCopy.ctaTitle(plan: .yearly, product: yearly, trialPeriod: nil),
            PaywallCopy.ctaTitle(plan: .monthly, product: monthly, trialPeriod: nil),
            PaywallCopy.ctaTitle(plan: .lifetime, product: lifetime, trialPeriod: nil),
        ]
        XCTAssertEqual(Set(titles).count, 4, "Each selection has its own call to action")
        XCTAssertTrue(titles[2].contains(monthly.displayPrice))
        XCTAssertTrue(titles[3].contains(lifetime.displayPrice))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note = PaywallCopy.billingNote(plan: .yearly, product: yearly, trialPeriod: trial, now: now)
        let firstCharge = PaywallCopy.chargeDateText(trial.date(after: now))
        XCTAssertTrue(note.contains(firstCharge), "The first charge date is visible before purchase")
        XCTAssertTrue(note.contains(yearly.displayPrice))
        XCTAssertTrue(PaywallCopy.billingNote(plan: .lifetime, product: lifetime, trialPeriod: nil, now: now).contains(lifetime.displayPrice))

        XCTAssertNotNil(PaywallCopy.planCard(plan: .yearly, product: yearly, monthly: monthly, trialPeriod: trial).badge, "Savings badge from real prices")
        XCTAssertNil(PaywallCopy.planCard(plan: .monthly, product: monthly, monthly: monthly, trialPeriod: nil).badge)
    }

    // Scenario 4: lifetime unlocks without renewal date.
    func testLifetimePurchase() async throws {
        _ = try await session.buyProduct(identifier: products.lifetime)
        await entitlements.refresh()
        let access = try XCTUnwrap(entitlements.state.activeAccess)
        XCTAssertEqual(access.plan, .lifetime)
        XCTAssertNil(access.expirationDate)
        XCTAssertNil(access.renewalDate)
    }

    // Scenario 11: lifetime bought while a subscription still renews.
    func testLifetimeWithActiveSubscriptionShowsExistingSubscription() async throws {
        _ = try await session.buyProduct(identifier: products.monthly)
        _ = try await session.buyProduct(identifier: products.lifetime)
        await entitlements.refresh()
        let access = try XCTUnwrap(entitlements.state.activeAccess)
        XCTAssertEqual(access.plan, .lifetime)
        XCTAssertEqual(access.coexistingSubscription?.plan, .monthly)
        XCTAssertEqual(access.coexistingSubscription?.willAutoRenew, true)
    }

    // Scenario 10 + spec §33.3: refund of lifetime keeps a still-valid subscription.
    func testRefundedLifetimeFallsBackToSubscription() async throws {
        _ = try await session.buyProduct(identifier: products.monthly)
        let lifetime = try await session.buyProduct(identifier: products.lifetime)
        try session.refundTransaction(identifier: UInt(lifetime.id))
        await entitlements.refresh()
        XCTAssertEqual(entitlements.state.activeAccess?.plan, .monthly)
    }

    func testRefundOfOnlyPurchaseRemovesAccess() async throws {
        let lifetime = try await session.buyProduct(identifier: products.lifetime)
        try session.refundTransaction(identifier: UInt(lifetime.id))
        await entitlements.refresh()
        XCTAssertFalse(entitlements.state.hasAccess)
    }

    // Scenario 8: auto-renew off keeps access until the end.
    func testDisabledAutoRenewKeepsAccess() async throws {
        let transaction = try await session.buyProduct(identifier: products.monthly)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        await entitlements.refresh()
        XCTAssertTrue(entitlements.state.hasAccess)
        XCTAssertEqual(entitlements.state.activeAccess?.willAutoRenew, false)
    }

    func testExpiredSubscriptionEndsAccess() async throws {
        _ = try await session.buyProduct(identifier: products.monthly)
        try session.expireSubscription(productIdentifier: products.monthly)
        await entitlements.refresh()
        XCTAssertFalse(entitlements.state.hasAccess)
    }

    // Scenario 9: billing retry vs grace period.
    func testBillingRetryWithoutGraceRemovesAccess() async throws {
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = false
        _ = try await session.buyProduct(identifier: products.monthly)
        try session.forceRenewalOfSubscription(productIdentifier: products.monthly)
        try await Task.sleep(for: .seconds(1))
        await entitlements.refresh()
        XCTAssertEqual(entitlements.state, .inactive(.billingRetry))
    }

    func testGracePeriodKeepsAccess() async throws {
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = true
        _ = try await session.buyProduct(identifier: products.monthly)
        try session.forceRenewalOfSubscription(productIdentifier: products.monthly)
        try await Task.sleep(for: .seconds(1))
        await entitlements.refresh()
        XCTAssertTrue(entitlements.state.hasAccess)
        XCTAssertEqual(entitlements.state.activeAccess?.inGracePeriod, true)
    }

    // Scenario 6: Ask to Buy stays pending and grants nothing.
    func testAskToBuyIsPendingWithoutAccess() async throws {
        session.askToBuyEnabled = true
        let map = try await loadProducts()
        let result = try await map[products.monthly]!.purchase()
        guard case .pending = result else { return XCTFail("Expected pending, got \(result)") }
        await entitlements.refresh()
        XCTAssertFalse(entitlements.state.hasAccess)
    }

    // Spec §33.2: month → year is scheduled for the next renewal, not a second subscription.
    func testMonthToYearIsScheduled() async throws {
        _ = try await session.buyProduct(identifier: products.monthly)
        _ = try await session.buyProduct(identifier: products.yearly)
        await entitlements.refresh()
        let access = try XCTUnwrap(entitlements.state.activeAccess)
        XCTAssertEqual(access.plan, .monthly)
        XCTAssertEqual(access.scheduledProductID, products.yearly)
        let active = await Self.activeSubscriptionCount()
        XCTAssertEqual(active, 1, "Only one subscription in the group is active")
    }

    private static func activeSubscriptionCount() async -> Int {
        var count = 0
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productType == .autoRenewable { count += 1 }
        }
        return count
    }

    // Scenario 14: price text comes from the storefront, not from the UI language.
    func testPriceTextIgnoresUILanguage() async throws {
        L10n.configure(languageCode: "ru", locale: Locale(identifier: "ru_RU"))
        defer { L10n.configure(languageCode: "en", locale: Locale(identifier: "en_US")) }
        let map = try await loadProducts()
        let text = PriceFormatter.pricePerPeriod(map[products.yearly]!)
        XCTAssertTrue(text.contains("59.99") || text.contains("59,99"), text)
        XCTAssertTrue(text.contains("$") || text.contains("US"), "Currency from storefront (USD): \(text)")
    }
}
