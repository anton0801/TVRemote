import StoreKit
import SwiftUI

/// Optional welcome bonus. Calm presentation: no casino visuals, sounds or countdowns.
struct BonusFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var revealed = false

    private var bonus: BonusController { model.bonus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if !bonus.isCampaignConfigured {
                    StateMessageView(systemImage: "gift", title: L10n.tr("bonus.unavailable.title"), message: L10n.tr("bonus.unavailable.message"))
                } else if !bonus.hasSomethingToShow {
                    // Paying users and former subscribers: nothing to spin, say why.
                    StateMessageView(systemImage: "gift", title: L10n.tr("bonus.notEligible.title"), message: L10n.tr("bonus.notEligible.message"))
                } else if let result = bonus.result, revealed || bonus.result != nil {
                    resultView(result)
                } else {
                    invitation
                }
            }
            .padding(Spacing.screen)
        }
        .appScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("common.close")) {
                    dismiss()
                }
            }
        }
        .task {
            bonus.invitationPresented()
            if bonus.isCampaignConfigured { await bonus.refreshAvailability() }
            if bonus.result != nil { revealed = true }
        }
    }

    // MARK: Invitation

    /// Design 31: a calm offer — gift, what may be available, one clear action, "Not now".
    @ViewBuilder
    private var invitation: some View {
        VStack(spacing: Spacing.s) {
            Image(ArtAsset.gift.rawValue)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 170)
                .accessibilityHidden(true)
            Text(L10n.tr("v2.offer.title"))
                .font(.appScreenTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.tr("bonus.invite.message"))
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        switch bonus.availability {
        case .checking, .disabled:
            ProgressView().frame(maxWidth: .infinity)
        case .unavailable:
            InlineNoticeView(kind: .info, text: L10n.tr("bonus.soldOut"))
        case .networkError:
            InlineNoticeView(kind: .warning, text: L10n.tr("bonus.networkError"), actionTitle: L10n.tr("action.retry")) {
                Task { await bonus.refreshAvailability() }
            }
        case .available(let sectors):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L10n.tr("bonus.odds", sectors.count))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextPrimary)
                ForEach(sectors) { sector in
                    HStack(spacing: Spacing.s) {
                        AppIconView("icon-calendar", size: 22).foregroundStyle(Color.appAccent)
                        Text(sectorTitle(sector)).font(.appBody).foregroundStyle(Color.appTextPrimary)
                    }
                }
            }
            .surfaceCard()
            Button(L10n.tr("v2.offer.check")) { reveal() }
                .buttonStyle(.primary)
                .accessibilityHint(L10n.tr("bonus.spin.hint"))
            VStack(spacing: Spacing.xxs) {
                Text(L10n.tr("bonus.terms.short"))
                Text(L10n.tr("v2.offer.note"))
            }
            .font(.appFootnote)
            .foregroundStyle(Color.appTextSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            if let rules = model.configuration.bonus.rulesURL {
                Button(L10n.tr("bonus.rules")) { openURL(rules) }
                    .font(.appFootnote)
                    .frame(maxWidth: .infinity)
            }
            Button(L10n.tr("v2.action.notNow")) {
                bonus.dismissInvitation()
                dismiss()
            }
            .buttonStyle(.secondary)
        }
    }

    /// The result is drawn and saved by the controller; it is shown right away, no animation.
    private func reveal() {
        guard bonus.drawIfNeeded() != nil else { return }
        revealed = true
    }

    // MARK: Result

    @ViewBuilder
    private func resultView(_ result: BonusResult) -> some View {
        Text(L10n.tr("bonus.result.title"))
            .font(.appHeroTitle)
            .accessibilityAddTraits(.isHeader)
        Text(sectorTitle(result.sector))
            .font(.appHeroTitle)
            .foregroundStyle(Color.appAccent)

        switch result.sector.kind {
        case .firstMonthDiscount:
            discountDetails(result)
        case .freeWeek:
            freeWeekDetails(result)
        }

        if let verified = result.verifiedAt {
            InlineNoticeView(kind: .success, text: L10n.tr("bonus.verified", verified.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))))
        } else {
            if let error = bonus.lastError {
                InlineNoticeView(kind: .warning, text: error.localizedMessage)
            }
            Button {
                Task {
                    if let url = await bonus.prepareRedemption() { openURL(url) }
                }
            } label: {
                if bonus.isReserving { ProgressView().tint(Color.appOnAccent) } else { Text(L10n.tr("bonus.activate")) }
            }
            .buttonStyle(.primary)
            .disabled(result.chosenPlan == nil || bonus.isReserving)
            if result.redemptionStartedAt != nil {
                Text(L10n.tr("bonus.awaitingApple"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                Button(L10n.tr("bonus.checkAgain")) { Task { await model.entitlements.refresh() } }
                    .buttonStyle(.textAction)
            }
            Text(L10n.tr("bonus.appleConditions"))
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
            Button(L10n.tr("bonus.standardPlans")) {
                dismiss()
                model.paywall.present(.remote)
            }
            .buttonStyle(.textAction)
        }
        HStack(spacing: Spacing.l) {
            Button(L10n.tr("legal.terms")) { openURL(model.configuration.termsURL) }
            if let privacy = model.configuration.privacyURL { Button(L10n.tr("legal.privacy")) { openURL(privacy) } }
        }
        .font(.appFootnote)
    }

    @ViewBuilder
    private func discountDetails(_ result: BonusResult) -> some View {
        let monthly = model.store.products[.monthly]
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let price = result.reservedCode?.firstPeriodPrice, let monthly {
                Text(L10n.tr("bonus.discount.prices", price, monthly.displayPrice))
            } else if let monthly {
                Text(L10n.tr("bonus.discount.standard", monthly.displayPrice))
            }
            Text(L10n.tr("bonus.discount.firstMonthOnly"))
            Text(L10n.tr("bonus.autoRenew"))
        }
        .font(.appSecondary)
        .foregroundStyle(Color.appTextSecondary)
    }

    @ViewBuilder
    private func freeWeekDetails(_ result: BonusResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if result.sector.plans.count > 1, result.redemptionStartedAt == nil {
                Picker(L10n.tr("bonus.freeWeek.then"), selection: Binding(get: { result.chosenPlan ?? .monthly }, set: { bonus.choosePlan($0) })) {
                    ForEach(result.sector.plans) { plan in
                        Text(L10n.tr("bonus.freeWeek.then.\(plan.rawValue)")).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                .onAppear { if result.chosenPlan == nil { bonus.choosePlan(.monthly) } }
            } else if result.sector.plans.count == 1 {
                Text(L10n.tr("bonus.freeWeek.onlyPlan", L10n.tr("plan.\(result.sector.plans[0].rawValue)")))
                    .font(.appFootnote)
            }
            if let plan = result.chosenPlan, let product = model.store.products[plan] {
                Text(L10n.tr("bonus.freeWeek.summary", PriceFormatter.pricePerPeriodSentence(product)))
                    .font(.appSecondary.weight(.semibold))
            }
            Text(L10n.tr("bonus.freeWeek.cancel"))
            Text(L10n.tr("bonus.freeWeek.notAdditional"))
        }
        .font(.appSecondary)
        .foregroundStyle(Color.appTextSecondary)
    }

    private func sectorTitle(_ sector: BonusSector) -> String {
        switch sector.kind {
        case .firstMonthDiscount(let percent): L10n.tr("bonus.sector.discount", percent)
        case .freeWeek: L10n.tr("bonus.sector.freeWeek")
        }
    }
}
