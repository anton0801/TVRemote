import Foundation
import Observation
import StoreKit

/// Optional welcome bonus (spec §34). Spinning buys nothing and grants nothing; access begins
/// only with a verified App Store transaction after the user redeems the Apple offer code.
@MainActor
@Observable
final class BonusController {
    enum Availability: Equatable {
        /// Feature flag off, service not configured, or rules/offers not ready.
        case disabled
        case checking
        case available([BonusSector])
        case unavailable
        /// The code service couldn't be reached — not the same as "no bonuses".
        case networkError
    }

    private(set) var availability: Availability = .disabled
    private(set) var result: BonusResult?
    private(set) var visitState = BonusRules.VisitState()
    private(set) var isReserving = false
    private(set) var lastError: AppError?
    /// Set when the invitation should be shown (consumed by the UI).
    var invitationPending = false

    private let configuration: AppConfiguration
    private let entitlements: EntitlementService
    private let store: StoreService
    private let analytics: AnalyticsService
    private let resultStore = JSONFileStore<BonusResult>(fileName: "bonus-result.json")
    private let visitStore = JSONFileStore<BonusRules.VisitState>(fileName: "bonus-visits.json")
    private var sessionStart: Date?
    private var sessionTimer: Task<Void, Never>?
    /// While true, returning to the foreground is not a new visit (system sheets, Settings, Mail…).
    private var expectingReturnUntil: Date?

    init(configuration: AppConfiguration, entitlements: EntitlementService, store: StoreService, analytics: AnalyticsService) {
        self.configuration = configuration
        self.entitlements = entitlements
        self.store = store
        self.analytics = analytics
        result = resultStore.load()
        visitState = visitStore.load() ?? BonusRules.VisitState()
    }

    var campaign: AppConfiguration.BonusCampaign { configuration.bonus }

    var isCampaignConfigured: Bool {
        campaign.enabled && campaign.codeServiceURL != nil && !configuration.appStoreID.isEmpty
    }

    /// Welcome bonus is only for people who never bought Remote Pro and have nothing pending.
    var isEligible: Bool {
        entitlements.state == .inactive(.neverPurchased) && entitlements.pendingProductIDs.isEmpty
    }

    /// Whether the bonus screen has anything for this user (eligible, or a won bonus being redeemed).
    var hasSomethingToShow: Bool {
        guard isCampaignConfigured else { return false }
        if let result, result.verifiedAt == nil, result.redemptionStartedAt != nil { return true }
        return isEligible
    }

    private var service: OfferCodeService? {
        guard isCampaignConfigured, let url = campaign.codeServiceURL else { return nil }
        return OfferCodeService(baseURL: url, campaignID: campaign.campaignID, rulesVersion: campaign.rulesVersion)
    }

    // MARK: Visits

    func appBecameActive() {
        if let until = expectingReturnUntil, until > .now {
            expectingReturnUntil = nil
            return
        }
        sessionStart = .now
        sessionTimer?.cancel()
        let minimum = TimeInterval(campaign.minimumSessionSeconds)
        sessionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minimum))
            guard !Task.isCancelled else { return }
            self?.completeVisit()
        }
    }

    func appWillResignActive() {
        sessionTimer?.cancel()
    }

    /// Call before opening a system sheet / external app so the return isn't a new visit.
    func expectReturn() {
        expectingReturnUntil = Date().addingTimeInterval(15 * 60)
    }

    /// A feature worked on a real TV (connection + command, shown photo, or confirmed frame).
    func recordVerifiedSuccess() {
        guard !visitState.hadVerifiedSuccess else { return }
        visitState.hadVerifiedSuccess = true
        visitStore.save(visitState)
    }

    private func completeVisit() {
        guard let start = sessionStart else { return }
        visitState = BonusRules.countVisit(visitState, sessionStart: start, sessionLength: Date().timeIntervalSince(start),
                                           minimumLength: TimeInterval(campaign.minimumSessionSeconds),
                                           minimumGap: TimeInterval(campaign.minimumMinutesBetweenVisits * 60))
        visitStore.save(visitState)
    }

    /// Called by the UI in a calm moment (no pairing, typing, payment, support or mirroring).
    func evaluateInvitation(isCalmMoment: Bool) async {
        guard isCampaignConfigured, result == nil else { return }
        let pending = !entitlements.pendingProductIDs.isEmpty
        guard BonusRules.shouldInvite(visitState, qualifyingVisitNumber: campaign.qualifyingVisitNumber, access: entitlements.state,
                                      hasPendingPurchase: pending, campaignAvailable: true, isCalmMoment: isCalmMoment)
        else { return }
        await refreshAvailability()
        guard case .available(let sectors) = availability, !sectors.isEmpty, isEligible else { return }
        // "Shown" is recorded only when the screen actually appears (`invitationPresented`), so an
        // invitation that couldn't be shown right now is kept for the next calm moment.
        invitationPending = true
    }

    /// The invitation screen is on screen now.
    func invitationPresented() {
        guard invitationPending else { return }
        invitationPending = false
        visitState.invitationShown = true
        visitStore.save(visitState)
        analytics.log(.bonusInvitationShown)
    }

    func dismissInvitation() {
        invitationPending = false
        visitState.dismissed = true
        visitStore.save(visitState)
        analytics.log(.bonusDismissed)
    }

    // MARK: Draw

    func refreshAvailability() async {
        guard let service else {
            availability = .disabled
            return
        }
        availability = .checking
        do {
            let storefront = await Storefront.current?.countryCode ?? ""
            let response = try await service.availability(storefront: storefront)
            await store.loadProducts()
            let monthly = store.products[.monthly]
            let sectors = response.sectors.compactMap { remote -> BonusSector? in
                guard let target = BonusSector.targetSectors.first(where: { $0.id == remote.id }) else { return nil }
                let plans = remote.plans.compactMap(PurchasePlan.init(rawValue:)).filter { target.plans.contains($0) }
                guard !plans.isEmpty else { return nil }
                let sector = BonusSector(id: target.id, kind: target.kind, plans: plans)
                // Never advertise a percentage the real price doesn't deliver.
                let offerPrice = remote.firstPeriodPrice?["monthly"].flatMap { text in
                    monthly.flatMap { try? Decimal(text, format: $0.priceFormatStyle) }
                }
                return BonusRules.isConsistent(sector, standardMonthly: monthly?.price, firstPeriodPrice: offerPrice) ? sector : nil
            }
            availability = response.active && !sectors.isEmpty ? .available(sectors) : .unavailable
        } catch {
            availability = (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain ? .networkError : .unavailable
        }
    }

    /// Draws once and persists the result before any animation.
    func drawIfNeeded() -> BonusResult? {
        if let result { return result }
        guard isEligible, case .available(let sectors) = availability else { return nil }
        var generator = SystemRandomNumberGenerator()
        guard let sector = BonusRules.draw(from: sectors, using: &generator) else { return nil }
        let newResult = BonusResult(resultID: UUID(), campaignID: campaign.campaignID, rulesVersion: campaign.rulesVersion,
                                    sector: sector, assignedAt: .now, chosenPlan: sector.plans.count == 1 ? sector.plans[0] : nil)
        result = newResult
        resultStore.save(newResult)
        analytics.log(.bonusAssigned(sector: sector.analyticsName))
        return newResult
    }

    func choosePlan(_ plan: PurchasePlan) {
        guard var current = result, current.sector.plans.contains(plan) else { return }
        // After redemption started, the plan can change only if the reserved code expired.
        if current.redemptionStartedAt != nil {
            guard let expires = current.reservedCode?.expiresAt, expires < .now else { return }
            current.redemptionStartedAt = nil
        }
        current.chosenPlan = plan
        if current.reservedCode?.plan != plan { current.reservedCode = nil }
        result = current
        resultStore.save(current)
    }

    // MARK: Activation

    /// Reserves the code for the chosen plan and returns Apple's redemption URL.
    func prepareRedemption() async -> URL? {
        guard var current = result, let plan = current.chosenPlan, let service else { return nil }
        guard isEligible || current.redemptionStartedAt != nil else { return nil }
        isReserving = true
        lastError = nil
        defer { isReserving = false }
        do {
            let code: ReservedCode
            if let existing = current.reservedCode, existing.plan == plan, (existing.expiresAt ?? .distantFuture) > .now {
                code = existing
            } else {
                let storefront = await Storefront.current?.countryCode ?? ""
                let reservation = try await service.reserve(resultID: current.resultID, sectorID: current.sector.id, plan: plan,
                                                            storefront: storefront, installationID: NotificationService.installationID())
                code = ReservedCode(plan: plan, code: reservation.code, expiresAt: reservation.expiresAt, firstPeriodPrice: reservation.firstPeriodPrice)
            }
            if let expires = code.expiresAt, expires < .now { throw AppError.offerExpired }
            current.reservedCode = code
            current.redemptionStartedAt = .now
            result = current
            resultStore.save(current)
            analytics.log(.offerRedemptionStarted(plan: plan.analyticsPlan))
            DiagnosticsLog.shared.record(.offerRedemptionStarted)
            expectReturn()
            return Self.redemptionURL(appID: configuration.appStoreID, code: code.code)
        } catch {
            let appError = AppError.wrap(error)
            lastError = appError
            current.failure = appError.code
            result = current
            resultStore.save(current)
            analytics.log(.offerFailed(plan: plan.analyticsPlan, errorCode: appError.code))
            DiagnosticsLog.shared.record(.offerFailed, error: appError)
            return nil
        }
    }

    /// Apple one-time code redemption link (format to verify against the offer page in
    /// App Store Connect before release; see OFFERS.md).
    nonisolated static func redemptionURL(appID: String, code: String) -> URL? {
        var components = URLComponents(string: "https://apps.apple.com/redeem")
        components?.queryItems = [
            URLQueryItem(name: "ctx", value: "offercodes"),
            URLQueryItem(name: "id", value: appID),
            URLQueryItem(name: "code", value: code),
        ]
        return components?.url
    }

    /// Called when a verified transaction with an offer arrives.
    func handleVerifiedPurchase(plan: PurchasePlan, phase: AccessPhase) {
        guard var current = result, current.redemptionStartedAt != nil, current.verifiedAt == nil,
              phase == .offerFreePeriod || phase == .offerDiscount
        else { return }
        current.verifiedAt = .now
        result = current
        resultStore.save(current)
        analytics.log(.offerVerified(plan: plan.analyticsPlan))
        DiagnosticsLog.shared.record(.offerVerified)
    }
}
