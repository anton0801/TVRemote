import Foundation

/// One of the three ways to buy Remote Pro. All unlock exactly the same features.
enum PurchasePlan: String, Codable, CaseIterable, Sendable, Identifiable {
    case monthly, yearly, lifetime

    var id: String { rawValue }

    var analyticsPlan: AnalyticsEvent.Plan {
        switch self {
        case .monthly: .monthly
        case .yearly: .yearly
        case .lifetime: .lifetime
        }
    }
}

/// How the current paid period is priced.
enum AccessPhase: String, Codable, Sendable {
    case standard
    /// Base introductory free trial (yearly, 3 days).
    case introductoryTrial
    /// Free period granted by an offer code / promotional offer.
    case offerFreePeriod
    /// Discounted first period from an offer code.
    case offerDiscount
}

/// Verified paid access. Produced only from StoreKit-verified transactions (or a cache of them).
struct ActiveAccess: Codable, Equatable, Sendable {
    var plan: PurchasePlan
    var productID: String
    var phase: AccessPhase
    var offerID: String?
    /// End of the current paid/free period (nil for lifetime).
    var expirationDate: Date?
    var willAutoRenew: Bool?
    var renewalDate: Date?
    /// Product the subscription will renew into when it differs from the current one (month → year).
    var scheduledProductID: String?
    var inGracePeriod: Bool
    var gracePeriodExpirationDate: Date?
    /// Original transaction ID of the subscription (for refund requests). Never logged.
    var transactionID: UInt64?
    /// When lifetime is active, the still-existing subscription (if StoreKit reports one).
    var coexistingSubscription: SubscriptionSummary?
    /// True when built from cache because StoreKit could not be refreshed.
    var isFromCache: Bool

    var isLifetime: Bool { plan == .lifetime }
}

struct SubscriptionSummary: Codable, Equatable, Sendable {
    var plan: PurchasePlan
    var productID: String
    var willAutoRenew: Bool?
    var expirationDate: Date?
    /// Free trial / offer period of that subscription (drives the trial reminder for lifetime owners).
    var phase: AccessPhase? = nil
    /// Apple is still retrying a failed payment for it.
    var inBillingRetry: Bool? = nil
}

enum InactiveReason: String, Codable, Sendable {
    case neverPurchased
    case expired
    /// Renewal payment failed and no grace period applies.
    case billingRetry
    case revoked
}

/// The single source of truth for Remote Pro access.
enum AccessState: Equatable, Sendable {
    /// Still loading or verification pending — never treated as "not purchased".
    case verifying
    case inactive(InactiveReason)
    case active(ActiveAccess)

    var hasAccess: Bool {
        if case .active = self { return true }
        return false
    }

    var activeAccess: ActiveAccess? {
        if case .active(let access) = self { return access }
        return nil
    }

    /// Status label used by support diagnostics (no payment details).
    var supportLabel: String {
        switch self {
        case .verifying: "unknown"
        case .inactive: "inactive"
        case .active(let access): access.plan.rawValue
        }
    }
}

// MARK: - Resolver input (StoreKit-independent, unit-tested)

struct TransactionFact: Equatable, Sendable {
    enum OfferKind: String, Sendable { case introductory, promotional, code, winBack }
    enum OfferPayment: String, Sendable { case freeTrial, payAsYouGo, payUpFront }

    var id: UInt64
    var originalID: UInt64
    var productID: String
    var purchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded: Bool
    var offerKind: OfferKind?
    var offerPayment: OfferPayment?
    var offerID: String?
}

struct SubscriptionStatusFact: Equatable, Sendable {
    enum State: String, Sendable { case subscribed, expired, inBillingRetryPeriod, inGracePeriod, revoked }

    var state: State
    var currentProductID: String
    var willAutoRenew: Bool
    var autoRenewPreference: String?
    var renewalDate: Date?
    var gracePeriodExpirationDate: Date?
    var expirationDate: Date?
    var transactionOriginalID: UInt64?
}

/// Pure function from verified StoreKit facts to `AccessState`.
///
/// Precedence: lifetime (not revoked) > subscription in `subscribed`/`inGracePeriod`.
/// Grace period is taken from StoreKit's status, not from comparing dates; billing retry
/// without grace means no access. A refund/revocation of one purchase does not remove access
/// granted by another still-valid purchase.
enum EntitlementResolver {
    static func resolve(
        entitlements: [TransactionFact],
        statuses: [SubscriptionStatusFact],
        products: AppConfiguration.Products,
        now: Date = .now
    ) -> AccessState {
        func plan(for productID: String) -> PurchasePlan? {
            switch productID {
            case products.monthly: .monthly
            case products.yearly: .yearly
            case products.lifetime: .lifetime
            default: nil
            }
        }

        let valid = entitlements.filter { $0.revocationDate == nil && !$0.isUpgraded && plan(for: $0.productID) != nil }
        let subscriptionStatus = preferredStatus(statuses)

        // Active subscription (from StoreKit status when available, otherwise from entitlements).
        var subscriptionAccess: ActiveAccess?
        if let status = subscriptionStatus, status.state == .subscribed || status.state == .inGracePeriod,
           let currentPlan = plan(for: status.currentProductID) {
            let transaction = valid.filter { $0.productID == status.currentProductID }.max { $0.purchaseDate < $1.purchaseDate }
            subscriptionAccess = makeSubscriptionAccess(plan: currentPlan, productID: status.currentProductID, transaction: transaction, status: status)
        } else if subscriptionStatus == nil,
                  // `Transaction.currentEntitlements` already contains only subscribed / in-grace
                  // subscriptions, so membership (not a date comparison) decides.
                  let transaction = valid.filter({ plan(for: $0.productID) != .lifetime })
                    .max(by: { $0.purchaseDate < $1.purchaseDate }),
                  let currentPlan = plan(for: transaction.productID) {
            subscriptionAccess = makeSubscriptionAccess(plan: currentPlan, productID: transaction.productID, transaction: transaction, status: nil)
        }

        if let lifetime = valid.first(where: { plan(for: $0.productID) == .lifetime }) {
            var access = ActiveAccess(
                plan: .lifetime, productID: lifetime.productID, phase: .standard, offerID: nil,
                expirationDate: nil, willAutoRenew: nil, renewalDate: nil, scheduledProductID: nil,
                inGracePeriod: false, gracePeriodExpirationDate: nil, transactionID: lifetime.id,
                coexistingSubscription: nil, isFromCache: false
            )
            if let subscriptionAccess {
                access.coexistingSubscription = SubscriptionSummary(
                    plan: subscriptionAccess.plan, productID: subscriptionAccess.productID,
                    willAutoRenew: subscriptionAccess.willAutoRenew, expirationDate: subscriptionAccess.expirationDate,
                    phase: subscriptionAccess.phase
                )
            } else if let status = subscriptionStatus, status.state == .inBillingRetryPeriod, status.willAutoRenew,
                      let retryPlan = plan(for: status.currentProductID) {
                // A failed renewal Apple still retries can charge later — the user must be told.
                access.coexistingSubscription = SubscriptionSummary(
                    plan: retryPlan, productID: status.currentProductID, willAutoRenew: true,
                    expirationDate: status.expirationDate, phase: nil, inBillingRetry: true
                )
            }
            return .active(access)
        }

        if let subscriptionAccess { return .active(subscriptionAccess) }

        // No access: explain why.
        if let status = subscriptionStatus {
            switch status.state {
            case .inBillingRetryPeriod: return .inactive(.billingRetry)
            case .revoked: return .inactive(.revoked)
            case .expired: return .inactive(.expired)
            case .subscribed, .inGracePeriod: break
            }
        }
        if entitlements.contains(where: { $0.revocationDate != nil }) { return .inactive(.revoked) }
        return .inactive(.neverPurchased)
    }

    /// With several statuses (e.g. family sharing), prefer one that grants access.
    private static func preferredStatus(_ statuses: [SubscriptionStatusFact]) -> SubscriptionStatusFact? {
        let rank: [SubscriptionStatusFact.State: Int] = [.subscribed: 0, .inGracePeriod: 1, .inBillingRetryPeriod: 2, .expired: 3, .revoked: 4]
        return statuses.min { (rank[$0.state] ?? 9) < (rank[$1.state] ?? 9) }
    }

    private static func makeSubscriptionAccess(plan: PurchasePlan, productID: String, transaction: TransactionFact?, status: SubscriptionStatusFact?) -> ActiveAccess {
        let phase: AccessPhase
        switch (transaction?.offerKind, transaction?.offerPayment) {
        case (.introductory?, .freeTrial?): phase = .introductoryTrial
        case (.code?, .freeTrial?), (.promotional?, .freeTrial?), (.winBack?, .freeTrial?): phase = .offerFreePeriod
        case (.code?, _), (.promotional?, _), (.winBack?, _): phase = transaction?.offerPayment == nil ? .standard : .offerDiscount
        default: phase = .standard
        }
        let scheduled = status?.autoRenewPreference.flatMap { $0 == productID ? nil : $0 }
        return ActiveAccess(
            plan: plan,
            productID: productID,
            phase: phase,
            offerID: transaction?.offerID,
            expirationDate: status?.expirationDate ?? transaction?.expirationDate,
            willAutoRenew: status?.willAutoRenew,
            renewalDate: status?.renewalDate ?? (status?.willAutoRenew == true ? (status?.expirationDate ?? transaction?.expirationDate) : nil),
            scheduledProductID: status?.willAutoRenew == true ? scheduled : nil,
            inGracePeriod: status?.state == .inGracePeriod,
            gracePeriodExpirationDate: status?.gracePeriodExpirationDate,
            transactionID: transaction?.originalID ?? status?.transactionOriginalID,
            coexistingSubscription: nil,
            isFromCache: false
        )
    }

    /// Keeps renewal details from a verified cache when the fresh result lacks them (status
    /// lookup failed). Only for the same product.
    static func merge(_ fresh: ActiveAccess, withCached cached: ActiveAccess) -> ActiveAccess {
        var merged = fresh
        if fresh.productID == cached.productID {
            if merged.willAutoRenew == nil { merged.willAutoRenew = cached.willAutoRenew }
            if merged.renewalDate == nil { merged.renewalDate = cached.renewalDate }
            if merged.scheduledProductID == nil { merged.scheduledProductID = cached.scheduledProductID }
            if merged.phase == .standard, cached.phase != .standard, (cached.expirationDate ?? .distantPast) > .now { merged.phase = cached.phase }
        }
        if merged.coexistingSubscription == nil { merged.coexistingSubscription = cached.coexistingSubscription }
        return merged
    }

    /// Offline rule: a cached verified lifetime stays valid until a verified revocation is seen;
    /// a cached subscription stays valid until its known end (+ grace end). If StoreKit cannot be
    /// refreshed shortly after that date, access is "verifying" for at most `verificationWindow`
    /// instead of an immediate paywall; after that it is inactive.
    static func resolveFromCache(_ cached: ActiveAccess?, now: Date = .now, verificationWindow: TimeInterval = 24 * 3600) -> AccessState {
        guard var cached else { return .verifying }
        cached.isFromCache = true
        if cached.isLifetime { return .active(cached) }
        let end = max(cached.gracePeriodExpirationDate ?? .distantPast, cached.expirationDate ?? .distantPast)
        if end > now { return .active(cached) }
        if now.timeIntervalSince(end) < verificationWindow { return .verifying }
        return .inactive(.expired)
    }
}
