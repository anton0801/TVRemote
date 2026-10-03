import Foundation
import Observation
import StoreKit

/// Remote Pro entitlement from verified StoreKit 2 data. No `isPremium` flag in UserDefaults:
/// the cache below only stores the last *verified* result for offline launches.
@MainActor
@Observable
final class EntitlementService {
    private(set) var state: AccessState = .verifying
    private(set) var lastRefresh: Date?
    private(set) var refreshFailed = false
    /// Product IDs with a purchase awaiting approval (Ask to Buy / SCA).
    private(set) var pendingProductIDs: Set<String> = []

    private let products: AppConfiguration.Products
    private let cache: KeychainStore
    private var updatesTask: Task<Void, Never>?
    private let analytics: AnalyticsService
    /// Notified with the transaction when a *new* verified purchase arrives (for UI + analytics).
    var onVerifiedPurchase: ((PurchasePlan, AccessPhase) -> Void)?
    /// Notified whenever the access state changes (e.g. to stop mirroring on revocation).
    var onStateChange: ((AccessState, AccessState) -> Void)?

    init(products: AppConfiguration.Products, analytics: AnalyticsService,
         cacheService: String = "app.TVRemoteScreenMirroring.entitlement") {
        self.products = products
        self.analytics = analytics
        cache = KeychainStore(service: cacheService)
        state = Self.launchState(cached: cachedAccess())
    }

    /// Before the first refresh of a launch, a cache that has run past its offline window means
    /// "we don't know yet" (the subscription has probably renewed), not "expired". The offline
    /// rule applies only once a refresh has actually failed.
    static func launchState(cached: ActiveAccess?, now: Date = .now) -> AccessState {
        let resolved = EntitlementResolver.resolveFromCache(cached, now: now)
        if case .inactive = resolved { return .verifying }
        return resolved
    }

    var hasAccess: Bool { state.hasAccess }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result, isNew: true)
            }
        }
        Task {
            // Deliver anything left unfinished by a previous run (e.g. app killed after payment).
            for await result in Transaction.unfinished {
                await handle(result, isNew: false)
            }
            await refresh()
        }
    }

    /// Recomputes access. Calls are serialized so an older, slower refresh can never overwrite
    /// the result of a newer one (e.g. foreground refresh racing a purchase delivery).
    func refresh() async {
        let previous = refreshChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        refreshChain = task
        await task.value
    }

    private var refreshChain: Task<Void, Never>?
    private var expiryCheck: Task<Void, Never>?

    private func performRefresh() async {
        var facts: [TransactionFact] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                facts.append(Self.fact(from: transaction))
            }
        }
        var statusFacts: [SubscriptionStatusFact] = []
        var statusAvailable = true
        do {
            statusFacts = try await subscriptionStatuses()
        } catch {
            statusAvailable = false
        }

        var resolved = EntitlementResolver.resolve(entitlements: facts, statuses: statusFacts, products: products)
        lastRefresh = .now
        if !statusAvailable, case .active(let access) = resolved, let cached = cachedAccess() {
            // Status lookup failed: keep renewal details we verified earlier instead of wiping them.
            resolved = .active(EntitlementResolver.merge(access, withCached: cached))
        }
        switch resolved {
        case .active(let access):
            refreshFailed = false
            store(access)
            apply(resolved)
            scheduleExpiryCheck(for: access)
        case .inactive(let reason):
            if !statusAvailable, facts.isEmpty, let cached = cachedAccess(), reason == .neverPurchased {
                // StoreKit unreachable and nothing local: fall back to the verified cache rules.
                refreshFailed = true
                apply(EntitlementResolver.resolveFromCache(cached))
            } else {
                refreshFailed = false
                if reason != .neverPurchased || !facts.isEmpty || statusAvailable { clearCache() }
                apply(resolved)
            }
        case .verifying:
            apply(resolved)
        }
        DiagnosticsLog.shared.record(refreshFailed ? .entitlementRefreshFailed : .entitlementRefreshed)
    }

    enum RestoreOutcome: Equatable {
        case found, nothingFound, cancelled, failed

        /// Message to show; nil when the user cancelled the Apple Account sign-in.
        var message: String? {
            switch self {
            case .found: L10n.tr("restore.success")
            case .nothingFound: L10n.tr("restore.nothing")
            case .failed: L10n.tr("restore.failed")
            case .cancelled: nil
            }
        }
    }

    /// Restore Purchases: syncs with the App Store (may prompt for Apple Account sign-in).
    /// Cancelling the sign-in is not "nothing found".
    func restore() async -> RestoreOutcome {
        DiagnosticsLog.shared.record(.restoreStarted)
        do {
            try await AppStore.sync()
        } catch {
            await refresh()
            DiagnosticsLog.shared.record(.restoreFinished, error: .entitlementRefreshFailed)
            if state.hasAccess { return .found }
            if case StoreKitError.userCancelled = error { return .cancelled }
            return .failed
        }
        await refresh()
        let found = state.hasAccess
        analytics.log(.restoreCompleted(found: found))
        DiagnosticsLog.shared.record(.restoreFinished, error: found ? nil : .restoreFoundNothing)
        return found ? .found : .nothingFound
    }

    /// While the app stays open, re-check right after a subscription's known end instead of
    /// keeping access until the next launch or foreground.
    private func scheduleExpiryCheck(for access: ActiveAccess) {
        expiryCheck?.cancel()
        guard !access.isLifetime, let end = [access.expirationDate, access.gracePeriodExpirationDate].compactMap({ $0 }).max() else { return }
        let delay = end.timeIntervalSinceNow + 5
        guard delay > 0, delay < 40 * 24 * 3600 else { return }
        expiryCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Handles a purchase result's transaction (called by the purchase flow).
    func process(_ verification: VerificationResult<Transaction>) async {
        await handle(verification, isNew: true)
    }

    func markPending(_ productID: String) {
        pendingProductIDs.insert(productID)
    }

    // MARK: Private

    private func handle(_ result: VerificationResult<Transaction>, isNew: Bool) async {
        guard case .verified(let transaction) = result else {
            // Unverified transactions never grant access.
            return
        }
        pendingProductIDs.remove(transaction.productID)
        let before = state
        await refresh()
        // Finish only after access has been recomputed and persisted (idempotent delivery).
        await transaction.finish()
        // Thank-you only for a new purchase: renewals (including an old subscription a lifetime
        // owner still has, or a plan change taking effect) are not purchases made now.
        if isNew, transaction.revocationDate == nil, transaction.reason == .purchase,
           !before.hasAccess || before.activeAccess?.productID != transaction.productID,
           let plan = plan(for: transaction.productID) {
            let phase = Self.fact(from: transaction)
            let accessPhase: AccessPhase = switch (phase.offerKind, phase.offerPayment) {
            case (.introductory?, .freeTrial?): .introductoryTrial
            case (_?, .freeTrial?): .offerFreePeriod
            case (_?, _?): .offerDiscount
            default: .standard
            }
            onVerifiedPurchase?(plan, accessPhase)
        }
    }

    private func apply(_ newState: AccessState) {
        let old = state
        state = newState
        if old != newState { onStateChange?(old, newState) }
    }

    private func plan(for productID: String) -> PurchasePlan? {
        switch productID {
        case products.monthly: .monthly
        case products.yearly: .yearly
        case products.lifetime: .lifetime
        default: nil
        }
    }

    private func subscriptionStatuses() async throws -> [SubscriptionStatusFact] {
        let loaded = try await Product.products(for: products.subscriptionIDs)
        guard let subscription = loaded.first?.subscription else { return [] }
        let statuses = try await subscription.status
        return statuses.compactMap { status -> SubscriptionStatusFact? in
            guard case .verified(let renewal) = status.renewalInfo else { return nil }
            var transactionExpiration: Date?
            var originalID: UInt64?
            if case .verified(let transaction) = status.transaction {
                transactionExpiration = transaction.expirationDate
                originalID = transaction.originalID
            }
            let state: SubscriptionStatusFact.State
            switch status.state {
            case .subscribed: state = .subscribed
            case .inGracePeriod: state = .inGracePeriod
            case .inBillingRetryPeriod: state = .inBillingRetryPeriod
            case .revoked: state = .revoked
            default: state = .expired
            }
            return SubscriptionStatusFact(
                state: state,
                currentProductID: renewal.currentProductID,
                willAutoRenew: renewal.willAutoRenew,
                autoRenewPreference: renewal.autoRenewPreference,
                renewalDate: renewal.renewalDate,
                gracePeriodExpirationDate: renewal.gracePeriodExpirationDate,
                expirationDate: transactionExpiration,
                transactionOriginalID: originalID
            )
        }
    }

    static func fact(from transaction: Transaction) -> TransactionFact {
        var kind: TransactionFact.OfferKind?
        var payment: TransactionFact.OfferPayment?
        var offerID: String?
        if #available(iOS 17.2, *) {
            if let offer = transaction.offer {
                switch offer.type {
                case .introductory: kind = .introductory
                case .promotional: kind = .promotional
                case .code: kind = .code
                default: kind = .winBack
                }
                offerID = offer.id
                switch offer.paymentMode {
                case .freeTrial?: payment = .freeTrial
                case .payAsYouGo?: payment = .payAsYouGo
                case .payUpFront?: payment = .payUpFront
                default: payment = nil
                }
            }
        } else {
            switch transaction.offerType {
            case .introductory?: kind = .introductory
            case .promotional?: kind = .promotional
            case .code?: kind = .code
            default: kind = nil
            }
            offerID = transaction.offerID
            // iOS 17.0–17.1: payment mode is only available in the signed JSON payload.
            let payload = (try? JSONSerialization.jsonObject(with: transaction.jsonRepresentation)) as? [String: Any]
            switch payload?["offerDiscountType"] as? String {
            case "FREE_TRIAL": payment = .freeTrial
            case "PAY_AS_YOU_GO": payment = .payAsYouGo
            case "PAY_UP_FRONT": payment = .payUpFront
            default: payment = nil
            }
        }
        return TransactionFact(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            offerKind: kind,
            offerPayment: payment,
            offerID: offerID
        )
    }

    // MARK: Cache (verified results only)

    private func cachedAccess() -> ActiveAccess? {
        cache.codable(ActiveAccess.self, for: "last-verified")
    }

    private func store(_ access: ActiveAccess) {
        var copy = access
        copy.isFromCache = false
        try? cache.setCodable(copy, for: "last-verified")
    }

    private func clearCache() {
        cache.remove("last-verified")
    }
}
