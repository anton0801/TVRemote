import Foundation

/// One wheel sector. A sector exists only if a matching Apple offer is configured.
struct BonusSector: Codable, Equatable, Sendable, Identifiable {
    enum Kind: Codable, Equatable, Sendable {
        /// Discount on the first month of the monthly plan.
        case firstMonthDiscount(percent: Int)
        /// 7 free days, then the chosen plan renews at its standard price.
        case freeWeek
    }

    let id: String
    let kind: Kind
    /// Plans with a real offer for this sector (freeWeek may cover monthly and/or yearly).
    let plans: [PurchasePlan]

    var analyticsName: String {
        switch kind {
        case .firstMonthDiscount(let percent): "discount_\(percent)"
        case .freeWeek: "free_week"
        }
    }

    /// Target configuration from the spec. Real availability comes from the campaign service.
    static let targetSectors: [BonusSector] = [5, 10, 15, 20, 25, 30].map {
        BonusSector(id: "d\($0)", kind: .firstMonthDiscount(percent: $0), plans: [.monthly])
    } + [BonusSector(id: "free7", kind: .freeWeek, plans: [.monthly, .yearly])]
}

/// The assigned result, persisted *before* the animation so closing the app or a crash
/// can never produce a second draw.
struct BonusResult: Codable, Equatable, Sendable {
    let resultID: UUID
    let campaignID: String
    let rulesVersion: String
    let sector: BonusSector
    let assignedAt: Date
    var chosenPlan: PurchasePlan?
    var reservedCode: ReservedCode?
    var redemptionStartedAt: Date?
    var verifiedAt: Date?
    var failure: String?
}

struct ReservedCode: Codable, Equatable, Sendable {
    let plan: PurchasePlan
    let code: String
    let expiresAt: Date?
    /// Exact first-period price shown before activation, e.g. "$6.29" (from the service config).
    let firstPeriodPrice: String?
}

/// Pure eligibility rules (unit-tested).
enum BonusRules {
    struct VisitState: Codable, Equatable, Sendable {
        var qualifyingVisits = 0
        var lastCountedVisitStart: Date?
        var invitationShown = false
        var dismissed = false
        var hadVerifiedSuccess = false
    }

    /// Counts a visit only if it lasted long enough and started long enough after the last
    /// counted one (returns from system sheets never start a new visit).
    static func countVisit(_ state: VisitState, sessionStart: Date, sessionLength: TimeInterval,
                           minimumLength: TimeInterval, minimumGap: TimeInterval) -> VisitState {
        guard sessionLength >= minimumLength else { return state }
        if let last = state.lastCountedVisitStart, sessionStart.timeIntervalSince(last) < minimumGap { return state }
        var next = state
        next.qualifyingVisits += 1
        next.lastCountedVisitStart = sessionStart
        return next
    }

    static func shouldInvite(_ state: VisitState, qualifyingVisitNumber: Int, access: AccessState, hasPendingPurchase: Bool,
                             campaignAvailable: Bool, isCalmMoment: Bool) -> Bool {
        guard campaignAvailable, isCalmMoment, !state.invitationShown, !state.dismissed, state.hadVerifiedSuccess,
              state.qualifyingVisits >= qualifyingVisitNumber, !hasPendingPurchase
        else { return false }
        // Only people who never purchased; former subscribers belong to a separate win-back offer.
        if case .inactive(.neverPurchased) = access { return true }
        return false
    }

    /// Uniform draw among the sectors that are really available (shown odds = real odds).
    static func draw(from sectors: [BonusSector], using generator: inout some RandomNumberGenerator) -> BonusSector? {
        sectors.randomElement(using: &generator)
    }

    /// A discount sector may be shown only if the real first-month price yields exactly the
    /// advertised percentage (rounded down). Free-week sectors are always consistent.
    static func isConsistent(_ sector: BonusSector, standardMonthly: Decimal?, firstPeriodPrice: Decimal?) -> Bool {
        guard case .firstMonthDiscount(let percent) = sector.kind else { return true }
        guard let standardMonthly, let firstPeriodPrice else { return false }
        return realDiscountPercent(standard: standardMonthly, offer: firstPeriodPrice) == percent
    }

    /// Real discount percentage from actual prices, rounded *down* so we never overstate.
    static func realDiscountPercent(standard: Decimal, offer: Decimal) -> Int {
        guard standard > 0, offer < standard else { return 0 }
        let value = NSDecimalNumber(decimal: (standard - offer) / standard * 100).doubleValue
        return Int(value.rounded(.down))
    }
}
