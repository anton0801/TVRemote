import XCTest
@testable import TVRemoteScreenMirroring

final class EntitlementResolverTests: XCTestCase {
    private let products = AppConfiguration.Products(monthly: "remote_pro_monthly", yearly: "remote_pro_yearly", lifetime: "remote_pro_lifetime", subscriptionGroupID: nil)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func transaction(_ id: UInt64, _ product: String, expires: TimeInterval? = 30 * 86400, revoked: Bool = false,
                             upgraded: Bool = false, offer: TransactionFact.OfferKind? = nil, payment: TransactionFact.OfferPayment? = nil) -> TransactionFact {
        TransactionFact(id: id, originalID: id, productID: product, purchaseDate: now.addingTimeInterval(-86400 + Double(id)),
                        expirationDate: expires.map { now.addingTimeInterval($0) }, revocationDate: revoked ? now : nil,
                        isUpgraded: upgraded, offerKind: offer, offerPayment: payment, offerID: nil)
    }

    private func status(_ state: SubscriptionStatusFact.State, product: String = "remote_pro_monthly", willRenew: Bool = true,
                        preference: String? = nil, grace: Date? = nil) -> SubscriptionStatusFact {
        SubscriptionStatusFact(state: state, currentProductID: product, willAutoRenew: willRenew, autoRenewPreference: preference ?? product,
                               renewalDate: now.addingTimeInterval(30 * 86400), gracePeriodExpirationDate: grace,
                               expirationDate: now.addingTimeInterval(30 * 86400), transactionOriginalID: 1)
    }

    func testNoPurchasesIsNeverPurchased() {
        XCTAssertEqual(EntitlementResolver.resolve(entitlements: [], statuses: [], products: products, now: now), .inactive(.neverPurchased))
    }

    func testMonthlySubscriptionActive() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly)], statuses: [status(.subscribed)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .monthly)
        XCTAssertEqual(state.activeAccess?.willAutoRenew, true)
        XCTAssertNil(state.activeAccess?.scheduledProductID)
    }

    func testYearlyTrialPhaseDetected() {
        let tx = transaction(1, products.yearly, expires: 3 * 86400, offer: .introductory, payment: .freeTrial)
        let state = EntitlementResolver.resolve(entitlements: [tx], statuses: [status(.subscribed, product: products.yearly)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.phase, .introductoryTrial)
    }

    func testOfferCodeFreeWeekAndDiscountPhases() {
        let free = transaction(1, products.monthly, offer: .code, payment: .freeTrial)
        XCTAssertEqual(EntitlementResolver.resolve(entitlements: [free], statuses: [status(.subscribed)], products: products, now: now).activeAccess?.phase, .offerFreePeriod)
        let discount = transaction(2, products.monthly, offer: .code, payment: .payAsYouGo)
        XCTAssertEqual(EntitlementResolver.resolve(entitlements: [discount], statuses: [status(.subscribed)], products: products, now: now).activeAccess?.phase, .offerDiscount)
    }

    func testAutoRenewOffKeepsAccessUntilEnd() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly)], statuses: [status(.subscribed, willRenew: false)], products: products, now: now)
        XCTAssertTrue(state.hasAccess)
        XCTAssertEqual(state.activeAccess?.willAutoRenew, false)
    }

    func testGracePeriodGrantsAccessEvenAfterExpirationDate() {
        // The subscription's expiration date already passed; StoreKit reports grace period.
        let tx = transaction(1, products.monthly, expires: -86400)
        let state = EntitlementResolver.resolve(entitlements: [tx], statuses: [status(.inGracePeriod, grace: now.addingTimeInterval(5 * 86400))], products: products, now: now)
        XCTAssertTrue(state.hasAccess)
        XCTAssertEqual(state.activeAccess?.inGracePeriod, true)
    }

    func testBillingRetryWithoutGraceHasNoAccess() {
        let state = EntitlementResolver.resolve(entitlements: [], statuses: [status(.inBillingRetryPeriod)], products: products, now: now)
        XCTAssertEqual(state, .inactive(.billingRetry))
    }

    func testExpiredSubscription() {
        XCTAssertEqual(EntitlementResolver.resolve(entitlements: [], statuses: [status(.expired, willRenew: false)], products: products, now: now), .inactive(.expired))
    }

    func testLifetimeWinsAndReportsStillRenewingSubscription() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly), transaction(2, products.lifetime, expires: nil)],
                                                statuses: [status(.subscribed)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .lifetime)
        XCTAssertNil(state.activeAccess?.expirationDate, "Lifetime has no renewal date")
        XCTAssertEqual(state.activeAccess?.coexistingSubscription?.plan, .monthly)
        XCTAssertEqual(state.activeAccess?.coexistingSubscription?.willAutoRenew, true)
    }

    func testLifetimeSurvivesExpiredSubscription() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(2, products.lifetime, expires: nil)],
                                                statuses: [status(.expired, willRenew: false)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .lifetime)
        XCTAssertNil(state.activeAccess?.coexistingSubscription)
    }

    func testRevokedLifetimeFallsBackToValidSubscription() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly), transaction(2, products.lifetime, expires: nil, revoked: true)],
                                                statuses: [status(.subscribed)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .monthly)
    }

    func testRevokedOnlyPurchaseIsRevoked() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(2, products.lifetime, expires: nil, revoked: true)], statuses: [], products: products, now: now)
        XCTAssertEqual(state, .inactive(.revoked))
    }

    func testMonthToYearIsScheduledNotImmediate() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly)],
                                                statuses: [status(.subscribed, preference: products.yearly)], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .monthly, "Current access stays monthly until renewal")
        XCTAssertEqual(state.activeAccess?.scheduledProductID, products.yearly)
    }

    func testUpgradedTransactionsAreIgnored() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.monthly, upgraded: true)], statuses: [], products: products, now: now)
        XCTAssertEqual(state, .inactive(.neverPurchased))
    }

    func testCurrentEntitlementMembershipWinsWithoutStatus() {
        // Offline: statuses unavailable, currentEntitlements still lists the subscription.
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, products.yearly, expires: -3600)], statuses: [], products: products, now: now)
        XCTAssertEqual(state.activeAccess?.plan, .yearly)
    }

    func testUnknownProductsNeverGrantAccess() {
        let state = EntitlementResolver.resolve(entitlements: [transaction(1, "some.other.product")], statuses: [], products: products, now: now)
        XCTAssertFalse(state.hasAccess)
    }

    // MARK: Offline cache

    private func access(_ plan: PurchasePlan, end: Date?) -> ActiveAccess {
        ActiveAccess(plan: plan, productID: "x", phase: .standard, offerID: nil, expirationDate: end, willAutoRenew: true, renewalDate: end,
                     scheduledProductID: nil, inGracePeriod: false, gracePeriodExpirationDate: nil, transactionID: 1,
                     coexistingSubscription: nil, isFromCache: false)
    }

    func testCachedLifetimeStaysActiveOffline() {
        let state = EntitlementResolver.resolveFromCache(access(.lifetime, end: nil), now: now.addingTimeInterval(400 * 86400))
        XCTAssertEqual(state.activeAccess?.plan, .lifetime)
        XCTAssertEqual(state.activeAccess?.isFromCache, true)
    }

    func testCachedSubscriptionValidUntilKnownEnd() {
        XCTAssertTrue(EntitlementResolver.resolveFromCache(access(.monthly, end: now.addingTimeInterval(3600)), now: now).hasAccess)
    }

    func testCachedSubscriptionBecomesVerifyingThenInactive() {
        let cached = access(.monthly, end: now)
        XCTAssertEqual(EntitlementResolver.resolveFromCache(cached, now: now.addingTimeInterval(3600)), .verifying)
        XCTAssertEqual(EntitlementResolver.resolveFromCache(cached, now: now.addingTimeInterval(2 * 86400)), .inactive(.expired))
    }

    func testNoCacheMeansVerifying() {
        XCTAssertEqual(EntitlementResolver.resolveFromCache(nil, now: now), .verifying)
    }
}
