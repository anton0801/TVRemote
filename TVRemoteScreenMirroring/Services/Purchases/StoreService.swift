import Foundation
import Observation
import StoreKit
import SwiftUI

/// Loads Remote Pro products and handles purchases. Displayed prices, currency and periods
/// always come from StoreKit for the user's storefront — never from the UI language.
@MainActor
@Observable
final class StoreService {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    enum Eligibility: Equatable {
        case unknown, eligible, notEligible
    }

    enum PurchaseOutcome: Equatable {
        case success(PurchasePlan)
        case pending
        case cancelled
        case failed(AppError)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var products: [PurchasePlan: Product] = [:]
    private(set) var yearlyTrialEligibility: Eligibility = .unknown
    private(set) var purchaseInProgress: PurchasePlan?

    let configuration: AppConfiguration.Products
    private let entitlements: EntitlementService
    private let analytics: AnalyticsService

    init(configuration: AppConfiguration.Products, entitlements: EntitlementService, analytics: AnalyticsService) {
        self.configuration = configuration
        self.entitlements = entitlements
        self.analytics = analytics
    }

    func productID(for plan: PurchasePlan) -> String {
        switch plan {
        case .monthly: configuration.monthly
        case .yearly: configuration.yearly
        case .lifetime: configuration.lifetime
        }
    }

    func plan(for productID: String) -> PurchasePlan? {
        PurchasePlan.allCases.first { self.productID(for: $0) == productID }
    }

    func loadProducts(force: Bool = false) async {
        if loadState == .loading { return }
        if loadState == .loaded, !force, products.count == 3 { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: configuration.all)
            var map: [PurchasePlan: Product] = [:]
            for product in loaded {
                if let plan = plan(for: product.id) { map[plan] = product }
            }
            products = map
            loadState = map.isEmpty ? .failed : .loaded
            await refreshEligibility()
        } catch {
            loadState = .failed
        }
    }

    func refreshEligibility() async {
        guard let yearly = products[.yearly], let subscription = yearly.subscription, subscription.introductoryOffer != nil else {
            yearlyTrialEligibility = products[.yearly] == nil ? .unknown : .notEligible
            return
        }
        yearlyTrialEligibility = await subscription.isEligibleForIntroOffer ? .eligible : .notEligible
    }

    /// Runs a purchase through SwiftUI's `PurchaseAction` (recommended on iOS 17+).
    func purchase(_ plan: PurchasePlan, using action: PurchaseAction) async -> PurchaseOutcome {
        guard purchaseInProgress == nil else { return .cancelled }
        guard let product = products[plan] else { return .failed(.storeProductsUnavailable) }
        purchaseInProgress = plan
        defer { purchaseInProgress = nil }
        analytics.log(.purchaseStarted(plan: plan.analyticsPlan))
        DiagnosticsLog.shared.record(.purchaseStarted)
        do {
            let result = try await action(product)
            switch result {
            case .success(let verification):
                guard case .verified = verification else {
                    analytics.log(.purchaseFailed(plan: plan.analyticsPlan, errorCode: AppError.purchaseFailed.code))
                    return .failed(.purchaseFailed)
                }
                await entitlements.process(verification)
                DiagnosticsLog.shared.record(.purchaseSucceeded)
                analytics.log(.purchaseCompleted(plan: plan.analyticsPlan))
                return .success(plan)
            case .pending:
                entitlements.markPending(product.id)
                DiagnosticsLog.shared.record(.purchasePending)
                analytics.log(.purchasePending(plan: plan.analyticsPlan))
                return .pending
            case .userCancelled:
                DiagnosticsLog.shared.record(.purchaseCancelled)
                analytics.log(.purchaseCancelled(plan: plan.analyticsPlan))
                return .cancelled
            @unknown default:
                return .failed(.purchaseFailed)
            }
        } catch {
            let appError: AppError
            if let storeError = error as? StoreKitError, case .userCancelled = storeError {
                analytics.log(.purchaseCancelled(plan: plan.analyticsPlan))
                return .cancelled
            } else if let purchaseError = error as? Product.PurchaseError, case .purchaseNotAllowed = purchaseError {
                appError = .purchaseNotAllowed
            } else {
                appError = .purchaseFailed
            }
            DiagnosticsLog.shared.record(.purchaseFailed, error: appError)
            analytics.log(.purchaseFailed(plan: plan.analyticsPlan, errorCode: appError.code))
            return .failed(appError)
        }
    }
}

/// Localized price texts built from StoreKit values (spec §15).
enum PriceFormatter {
    /// "$59.99 / year" style, using StoreKit's localized display price.
    static func pricePerPeriod(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        return L10n.tr(period.unit == .year ? "price.perYear" : "price.perMonth", product.displayPrice)
    }

    /// "$59.99 per year" style for running sentences.
    static func pricePerPeriodSentence(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        return L10n.tr(period.unit == .year ? "price.perYear.sentence" : "price.perMonth.sentence", product.displayPrice)
    }

    /// "Start 3-day free trial" — built from the real offer period.
    static func trialCallToAction(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: L10n.tr("paywall.cta.trial.days", period.value)
        case .week: L10n.tr("paywall.cta.trial.days", period.value * 7)
        case .month: L10n.tr("paywall.cta.trial.months", period.value)
        case .year: L10n.tr("paywall.cta.trial.months", period.value * 12)
        @unknown default: L10n.tr("paywall.cta.trial.generic")
        }
    }

    /// Localized "3 days" / "1 week" for an offer period.
    static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: L10n.tr("period.days", period.value)
        case .week: period.value == 1 ? L10n.tr("period.days", 7) : L10n.tr("period.weeks", period.value)
        case .month: L10n.tr("period.months", period.value)
        case .year: L10n.tr("period.years", period.value)
        @unknown default: ""
        }
    }

    /// Yearly vs 12 monthly payments, computed from real storefront prices; nil if not a saving.
    static func yearlySavings(monthly: Product, yearly: Product) -> (amount: String, percent: Int)? {
        let twelveMonths = monthly.price * 12
        let difference = twelveMonths - yearly.price
        guard difference > 0, twelveMonths > 0 else { return nil }
        let percent = NSDecimalNumber(decimal: difference / twelveMonths * 100).doubleValue
        let formatted = yearly.priceFormatStyle.format(difference)
        return (formatted, Int(percent.rounded(.down)))
    }

    static func monthlyEquivalent(of yearly: Product) -> String {
        yearly.priceFormatStyle.format(yearly.price / 12)
    }

    static func twelveMonthlyPayments(_ monthly: Product) -> String {
        monthly.priceFormatStyle.format(monthly.price * 12)
    }
}
