import StoreKit
import SwiftUI

/// Full-screen paywall (spec §15, redesign brief §8). Same prices, terms and entitlement in both
/// contexts; only the headline and benefit order differ. Every price text comes from StoreKit.
/// Always dark, like onboarding: the hero illustration is a dark scene.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.purchase) private var purchase
    @Environment(\.openURL) private var openURL
    let request: PaywallPresenter.Request

    @State private var selected: PurchasePlan = .yearly
    @State private var outcome: OutcomeMessage?
    @State private var isRestoring = false
    @State private var showLifetimeNote = false
    @State private var isChecking = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum OutcomeMessage: Equatable {
        case pending, failed(AppError), restoreMessage(String)
    }

    private var store: StoreService { model.store }
    private var isBusy: Bool { store.purchaseInProgress != nil || isRestoring }

    /// Full-screen states that replace the plans (designs 34, 30, 43).
    private enum Screen: Equatable { case plans, unavailable, pending, unconfirmed(AppError) }

    private var screen: Screen {
        if outcome == .pending || !model.entitlements.pendingProductIDs.isEmpty { return .pending }
        if case .failed(let error) = outcome { return .unconfirmed(error) }
        if store.loadState == .failed { return .unavailable }
        return .plans
    }

    var body: some View {
        Group {
            switch screen {
            case .plans: plansScreen
            case .unavailable: unavailableScreen
            case .pending: pendingScreen
            case .unconfirmed(let error): unconfirmedScreen(error)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            await store.loadProducts()
            await store.refreshEligibility()
            selectAvailablePlan()
        }
        .onChange(of: store.products.count) { _, _ in selectAvailablePlan() }
        .onChange(of: selected) { _, plan in
            model.analytics.log(.planSelected(plan: plan.analyticsPlan))
            if case .restoreMessage = outcome { outcome = nil }
        }
        .alert(L10n.tr("paywall.lifetime.noteTitle"), isPresented: $showLifetimeNote) {
            Button(L10n.tr("paywall.lifetime.continue")) { Task { await buy(.lifetime) } }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("paywall.lifetime.note"))
        }
    }

    // MARK: Plans (19, loading 42)

    private var plansScreen: some View {
        GeometryReader { proxy in
            let heroHeight = PaywallLayout.heroHeight(screenHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            // The purchase bar sits below the scroll view, so plan cards can never slide under it.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        Image(ArtAsset.paywallHero.rawValue)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: heroHeight)
                            .frame(maxWidth: proxy.size.width)
                            .clipped()
                            .overlay(alignment: .bottom) {
                                LinearGradient(colors: [Color.appBackground.opacity(0), Color.appBackground], startPoint: .top, endPoint: .bottom)
                                    .frame(height: heroHeight * 0.45)
                            }
                            .accessibilityHidden(true)
                        content
                            .padding(.horizontal, Spacing.screen)
                            .padding(.top, -Spacing.xl)
                            .padding(.bottom, Spacing.m)
                        if dynamicTypeSize.isAccessibilitySize { bottomBar }
                    }
                }
                .ignoresSafeArea(edges: .top)
                .scrollBounceBehavior(.basedOnSize)
                .overlay(alignment: .top) { topBar(safeTop: proxy.safeAreaInsets.top) }
                if !dynamicTypeSize.isAccessibilitySize { bottomBar }
            }
        }
    }

    // MARK: Top bar (always readable over the image)

    private func topBar(safeTop: CGFloat) -> some View {
        HStack {
            closeButton
            Spacer()
            Button {
                Task { await restore() }
            } label: {
                Group {
                    if isRestoring { ProgressView().tint(.appAccent) } else { Text(L10n.tr("paywall.restore")) }
                }
                .font(.appSecondary.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: 36)
                .background(Color.appBackground.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
                .frame(minHeight: HitTarget.minimum)
            }
            .disabled(isBusy)
            .accessibilityIdentifier("paywall.restore")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, safeTop > 0 ? 0 : Spacing.s)
    }

    private var closeButton: some View {
        Button {
            model.paywall.dismiss()
        } label: {
            AppIconView("icon-close", size: 16)
                .foregroundStyle(Color.appTextPrimary)
                .frame(width: 40, height: 40)
                .background(Color.appBackground.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                .frame(width: HitTarget.minimum, height: HitTarget.minimum)
        }
        .accessibilityLabel(L10n.tr("common.close"))
        .accessibilityIdentifier("paywall.close")
        .disabled(store.purchaseInProgress != nil)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: Spacing.m) {
            VStack(spacing: Spacing.xs) {
                Text(L10n.tr("paywall.\(request.context.rawValue).title"))
                    .font(.appHeroTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.tr("paywall.\(request.context.rawValue).subtitle"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let feature = request.feature {
                    Text(L10n.tr("paywall.reason.\(feature.rawValue)"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            benefits
            compatibilityNote
            bonusCard
            plans
            if case .restoreMessage(let text) = outcome {
                InlineNoticeView(kind: .info, text: text)
            }
            VStack(spacing: Spacing.xs) {
                Text(L10n.tr("paywall.samePlans"))
                if store.products[.monthly] != nil || store.products[.yearly] != nil {
                    Text(L10n.tr("paywall.terms.full"))
                }
            }
            .font(.appFinePrint)
            .foregroundStyle(Color.appTextSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Before purchase, say plainly what this TV supports; buying never adds compatibility.
    @ViewBuilder
    private var compatibilityNote: some View {
        if let id = request.deviceID ?? model.devices.selectedDeviceID, let device = model.devices.device(id) {
            if device.capabilities[.screenMirroring].support == .unsupported {
                CompatibilityPill(symbol: "icon-info", tint: .appAccent, text: L10n.tr("paywall.compat.noMirroring", device.displayName))
            } else if device.capabilities[.remoteControl].isUsable {
                CompatibilityPill(symbol: "icon-check-circle", tint: .appSuccess, text: L10n.tr("paywall.compat.checked", device.displayName))
            }
        }
    }

    /// Three benefit tiles (design 19); mirroring context puts sharing first.
    private var benefits: some View {
        let tiles: [(String, String)] = request.context == .remote
            ? [("icon-tv", "v2.pro.unlimited"), ("icon-keyboard", "v2.pro.shortcuts"), ("icon-photo", "v2.pro.sharing")]
            : [("icon-photo", "v2.pro.sharing"), ("icon-tv", "v2.pro.unlimited"), ("icon-keyboard", "v2.pro.shortcuts")]
        let ax = dynamicTypeSize.isAccessibilitySize
        let row = ax ? AnyLayout(VStackLayout(spacing: Spacing.xs)) : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.xs))
        let tile = ax ? AnyLayout(HStackLayout(spacing: Spacing.s)) : AnyLayout(VStackLayout(spacing: Spacing.xs))
        return row {
            ForEach(tiles, id: \.1) { icon, key in
                tile {
                    AppIconView(icon, size: 30).foregroundStyle(Color.appAccent)
                    Text(L10n.tr(key))
                        .font(.appCaption)
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(ax ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                    if ax { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, minHeight: ax ? nil : 84, alignment: ax ? .leading : .top)
                .padding(.vertical, Spacing.s)
                .padding(.horizontal, Spacing.xxs)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A welcome bonus the user already won is activated through Apple's offer-code flow.
    @ViewBuilder
    private var bonusCard: some View {
        if model.bonus.isCampaignConfigured, let result = model.bonus.result, result.verifiedAt == nil {
            HStack(spacing: Spacing.s) {
                AppIconView("icon-gift", size: 22).foregroundStyle(Color.appAccent)
                Text(L10n.tr("paywall.bonus.waiting"))
                    .font(.appSecondary)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Spacing.xs)
                Button(L10n.tr("paywall.bonus.open")) {
                    model.present(.bonus)
                }
                .font(.appSecondary.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .frame(minHeight: HitTarget.minimum)
            }
            .padding(.horizontal, Spacing.m)
            .background(Color.appAccentTint, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch store.loadState {
        case .idle, .loading, .failed:
            // Design 42: skeleton without any price.
            VStack(spacing: Spacing.xs) {
                ForEach(0..<3, id: \.self) { _ in SkeletonPlanRow() }
                Text(L10n.tr("v2.purchase.loadingPlans"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.top, Spacing.xxs)
            }
            .padding(Spacing.s)
            .background(Color.appSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("paywall.loading"))
        case .loaded:
            VStack(spacing: Spacing.xs) {
                ForEach(PurchasePlan.displayOrder) { plan in
                    if let product = store.products[plan] {
                        PlanCardView(model: planModel(plan, product: product), isSelected: selected == plan) {
                            selected = plan
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
                    }
                }
                if store.products.count < 3 {
                    InlineNoticeView(kind: .info, text: L10n.tr("paywall.someUnavailable"))
                }
            }
        }
    }

    private func planModel(_ plan: PurchasePlan, product: Product) -> PlanCardModel {
        let trialEligible = plan == .yearly && store.yearlyTrialEligibility == .eligible
            && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        return PaywallCopy.planCard(plan: plan, product: product, monthly: store.products[.monthly],
                                    trialPeriod: trialEligible ? product.subscription?.introductoryOffer?.period : nil)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: Spacing.xs) {
            if store.loadState == .loaded, let product = store.products[selected] {
                Button {
                    if selected == .lifetime, hasRenewingSubscription {
                        showLifetimeNote = true
                    } else {
                        Task { await buy(selected) }
                    }
                } label: {
                    if store.purchaseInProgress != nil {
                        ProgressView().tint(Color.appOnAccent)
                    } else {
                        Text(ctaTitle(product))
                    }
                }
                .buttonStyle(.primary)
                .disabled(isBusy)
                .accessibilityHint(billingNote(product) + (selected == .lifetime ? "" : " " + L10n.tr("paywall.terms.full")))
                .accessibilityIdentifier("paywall.purchase")

                Text(billingNote(product))
                    .font(.appFinePrint)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.note")
            } else {
                Button {} label: {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().tint(Color.appOnAccent)
                        Text(L10n.tr("paywall.loadingShort"))
                    }
                }
                .buttonStyle(.primary)
                .disabled(true)
            }
            legalLinks
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.s)
        .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
    }

    private var legalLinks: some View {
        HStack(spacing: Spacing.s) {
            Button(L10n.tr("v2.legal.terms")) { openURL(model.configuration.termsURL) }
                .underline()
            if let privacy = model.configuration.privacyURL {
                Text(verbatim: "|").accessibilityHidden(true)
                Button(L10n.tr("v2.legal.privacy")) { openURL(privacy) }
                    .underline()
            }
        }
        .font(.appFinePrint.weight(.medium))
        .foregroundStyle(Color.appTextSecondary)
        .frame(minHeight: 32)
    }

    /// A subscription that can still charge: active, or a failed renewal Apple keeps retrying.
    /// Buying lifetime never cancels it, so the user is told first.
    private var hasRenewingSubscription: Bool {
        switch model.entitlements.state {
        case .active(let access): access.isLifetime == false
        case .inactive(.billingRetry): true
        default: false
        }
    }

    /// Yearly is preselected; if it isn't available in this storefront, pick the next plan so
    /// the purchase button never disappears.
    private func selectAvailablePlan() {
        guard store.products[selected] == nil, let first = PurchasePlan.displayOrder.first(where: { store.products[$0] != nil }) else { return }
        selected = first
    }

    private func ctaTitle(_ product: Product) -> String {
        let trial = selected == .yearly && store.yearlyTrialEligibility == .eligible
            && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        return PaywallCopy.ctaTitle(plan: selected, product: product, trialPeriod: trial ? product.subscription?.introductoryOffer?.period : nil)
    }

    private func billingNote(_ product: Product) -> String {
        let trial = selected == .yearly && store.yearlyTrialEligibility == .eligible
            && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        return PaywallCopy.billingNote(plan: selected, product: product, trialPeriod: trial ? product.subscription?.introductoryOffer?.period : nil, now: .now)
    }

    // MARK: States (34, 30, 43)

    private var unavailableScreen: some View {
        PaywallStateScreen(
            close: { model.paywall.dismiss() },
            art: nil, systemIcon: "bag.badge.questionmark",
            title: L10n.tr("v2.purchase.unavailable"), message: L10n.tr("v2.purchase.unavailable.body")
        ) {
            Button {
                Task { await store.loadProducts(force: true) }
            } label: {
                Label { Text(L10n.tr("v2.action.retry")) } icon: { ButtonIcon("icon-refresh") }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("paywall.retry")
            Button(L10n.tr("v2.purchase.without")) { model.paywall.dismiss() }
                .buttonStyle(.secondary)
            Button(L10n.tr("settings.contact")) { contactSupport() }
                .buttonStyle(.textAction)
        }
    }

    private var pendingScreen: some View {
        PaywallStateScreen(
            close: { model.paywall.dismiss() },
            art: ArtAsset.pending.rawValue, systemIcon: nil,
            title: L10n.tr("v2.purchase.pending"), message: L10n.tr("v2.purchase.pending.body"),
            note: L10n.tr("purchase.pending.note")
        ) {
            Button {
                Task { await checkStatus() }
            } label: {
                if isChecking { ProgressView().tint(.appOnAccent) } else { Text(L10n.tr("v2.purchase.check")) }
            }
            .buttonStyle(.primary)
            .disabled(isChecking)
            Button(L10n.tr("v2.action.close")) { model.paywall.dismiss() }
                .buttonStyle(.secondary)
            Button(L10n.tr("settings.contact")) { contactSupport() }
                .buttonStyle(.textAction)
        }
    }

    private func unconfirmedScreen(_ error: AppError) -> some View {
        PaywallStateScreen(
            close: { model.paywall.dismiss() },
            art: ArtAsset.connectionLost.rawValue, systemIcon: nil,
            title: L10n.tr("v2.purchase.unconfirmed"), message: L10n.tr("v2.purchase.unconfirmedBody"),
            note: error.localizedMessage
        ) {
            Button {
                Task { await checkStatus() }
            } label: {
                if isChecking { ProgressView().tint(.appOnAccent) } else { Text(L10n.tr("v2.purchase.checkStatus")) }
            }
            .buttonStyle(.primary)
            .disabled(isChecking)
            Button(L10n.tr("v2.purchase.backPlans")) { outcome = nil }
                .buttonStyle(.secondary)
            VStack(spacing: 0) {
                Button { Task { await restore() } } label: {
                    SettingsRowLabel(symbol: "icon-restore", title: L10n.tr("v2.action.restore"), tint: .appAccent)
                }
                .disabled(isBusy)
                SettingsDivider()
                Button { contactSupport() } label: {
                    SettingsRowLabel(symbol: "icon-mail", title: L10n.tr("settings.contact"), tint: .appAccent)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.s)
        }
    }

    private func contactSupport() {
        model.paywall.dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.openSupport(category: .paidNoAccess, feature: "paywall")
        }
    }

    // MARK: Actions

    private func buy(_ plan: PurchasePlan) async {
        outcome = nil
        model.bonus.expectReturn()
        switch await store.purchase(plan, using: purchase) {
        case .success:
            if model.paywall.request != nil { model.paywall.completed(with: plan) }
        case .pending:
            outcome = .pending
        case .cancelled:
            break // back to the normal paywall, no error message
        case .failed(let error):
            outcome = .failed(error)
        }
    }

    /// Asks the App Store for the current state before offering anything again.
    private func checkStatus() async {
        isChecking = true
        await model.entitlements.refresh()
        isChecking = false
        if let access = model.entitlements.state.activeAccess {
            model.paywall.completed(with: access.plan)
        } else if model.entitlements.pendingProductIDs.isEmpty {
            outcome = nil // nothing pending and no access: back to the plans
        }
    }

    private func restore() async {
        isRestoring = true
        outcome = nil
        model.bonus.expectReturn()
        let result = await model.entitlements.restore()
        isRestoring = false
        if result == .found {
            model.paywall.completed(with: model.entitlements.state.activeAccess?.plan ?? .yearly)
        } else if let message = result.message {
            outcome = .restoreMessage(message)
        }
    }
}

enum PaywallLayout {
    /// Decorative hero, never more than the top third; it shrinks first on shorter screens so
    /// the recommended plan stays above the purchase bar.
    static func heroHeight(screenHeight: CGFloat) -> CGFloat {
        if screenHeight < 700 { return min(screenHeight * 0.2, 140) }
        if screenHeight < 900 { return (screenHeight * 0.25).rounded() }
        return min(screenHeight * 0.3, 300).rounded()
    }
}

extension PurchasePlan {
    /// Yearly first (recommended), then monthly, then lifetime.
    static let displayOrder: [PurchasePlan] = [.yearly, .monthly, .lifetime]
}

/// One-line "checked on this TV" statement; quieter than a notice card.
private struct CompatibilityPill: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            AppIconView(symbol, size: 18, relativeTo: .footnote)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.appFootnote)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Plan card

struct PlanCardModel: Equatable {
    var title: String
    var price: String
    var period: String
    var detail: String
    var badge: String?
    /// Short amber line under the plan name ("3 days free"), only from real offer data.
    var highlight: String? = nil
    /// "/ month" after the price; nil for the one-time purchase.
    var perPeriod: String? = nil

    static let placeholder = PlanCardModel(title: "Remote Pro Yearly", price: "$00.00", period: "per year", detail: "Billed once a year", badge: nil)
}

/// Compact plan row (design 19): radio, plan name, optional trial line, full price of the period.
struct PlanCardView: View {
    let model: PlanCardModel
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        Button(action: action) {
            layout {
                RadioIndicator(isOn: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.appPlanTitle)
                        .foregroundStyle(Color.appTextPrimary)
                    if let highlight = model.highlight ?? model.badge {
                        Text(highlight)
                            .font(.appFootnote.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                if !stacked { Spacer(minLength: Spacing.xs) }
                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                    if let perPeriod = model.perPeriod {
                        (Text(model.price).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                            + Text(verbatim: " ") + Text(perPeriod).font(.appSecondary).foregroundStyle(Color.appTextSecondary))
                            .fixedSize()
                    } else {
                        Text(model.price).font(.appHeadline).foregroundStyle(Color.appTextPrimary).fixedSize()
                        Text(model.period).font(.appCaption).foregroundStyle(Color.appTextSecondary)
                    }
                }
                .multilineTextAlignment(stacked ? .leading : .trailing)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity, minHeight: HitTarget.row, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? Color.appAccentTint : Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(isSelected ? Color.appAccentFill : Color.appBorder.opacity(0.8), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([model.title, model.highlight, model.badge, model.price, model.period, model.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Loading placeholder for one plan (no fake price).
private struct SkeletonPlanRow: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.appSurfaceRaised).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.appSurfaceRaised).frame(width: 120, height: 8)
                Capsule().fill(Color.appSurfaceRaised.opacity(0.7)).frame(width: 80, height: 6)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.appSurfaceRaised).frame(width: 56, height: 22)
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: HitTarget.row)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Full-screen purchase state (designs 30, 34, 43): close, illustration, title, text, actions.
struct PaywallStateScreen<Actions: View>: View {
    let close: () -> Void
    let art: String?
    let systemIcon: String?
    let title: String
    let message: String
    var note: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                HStack {
                    Spacer()
                    Button(action: close) {
                        AppIconView("icon-close", size: 16)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 40, height: 40)
                            .background(Color.appSurface, in: Circle())
                            .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                    }
                    .accessibilityLabel(L10n.tr("common.close"))
                    .accessibilityIdentifier("paywall.close")
                }
                Group {
                    if let art {
                        Image(art).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 260, maxHeight: 190)
                    } else if let systemIcon {
                        Image(systemName: systemIcon)
                            .font(.system(size: 56, weight: .regular))
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 150, height: 150)
                            .background(Circle().fill(Color.appSurface))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color.appOnAccent, Color.appAccent)
                                    .offset(x: -14, y: -14)
                            }
                    }
                }
                .accessibilityHidden(true)
                Text(title)
                    .font(.appScreenTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: Spacing.xs) { actions() }
                    .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Copy (pure, unit-tested)

/// All paywall strings derived from StoreKit values for the selected plan.
enum PaywallCopy {
    static func planCard(plan: PurchasePlan, product: Product, monthly: Product?, trialPeriod: Product.SubscriptionPeriod?) -> PlanCardModel {
        switch plan {
        case .yearly:
            var detail: String
            if let trialPeriod {
                detail = L10n.tr("paywall.yearly.trialDetail", PriceFormatter.periodText(trialPeriod), PriceFormatter.pricePerPeriodSentence(product))
            } else {
                detail = L10n.tr("paywall.yearly.detail")
            }
            var badge: String?
            if let monthly, let savings = PriceFormatter.yearlySavings(monthly: monthly, yearly: product) {
                detail += "\n" + L10n.tr("paywall.yearly.savings", savings.amount, monthly.displayPrice)
                badge = L10n.tr("paywall.yearly.badge")
            }
            return PlanCardModel(title: L10n.tr("plan.yearly"), price: product.displayPrice, period: L10n.tr("paywall.period.year"), detail: detail, badge: badge,
                                 highlight: trialPeriod.map { L10n.tr("paywall.trialFree", PriceFormatter.periodText($0)) },
                                 perPeriod: L10n.tr("paywall.per.year"))
        case .monthly:
            return PlanCardModel(title: L10n.tr("plan.monthly"), price: product.displayPrice, period: L10n.tr("paywall.period.month"),
                                 detail: L10n.tr("paywall.monthly.detail"), badge: nil, perPeriod: L10n.tr("paywall.per.month"))
        case .lifetime:
            return PlanCardModel(title: L10n.tr("plan.lifetime"), price: product.displayPrice, period: L10n.tr("v2.plan.once"),
                                 detail: L10n.tr("paywall.lifetime.detail"), badge: nil)
        }
    }

    static func ctaTitle(plan: PurchasePlan, product: Product, trialPeriod: Product.SubscriptionPeriod?) -> String {
        switch plan {
        case .yearly where trialPeriod != nil:
            return PriceFormatter.trialCallToAction(trialPeriod!)
        case .yearly, .monthly:
            return L10n.tr("paywall.cta.subscribe", PriceFormatter.pricePerPeriodSentence(product))
        case .lifetime:
            return L10n.tr("paywall.cta.lifetime.price", product.displayPrice)
        }
    }

    /// Date style of the first charge in the note ("Sep 30, 2026", "30 сент. 2026 г.").
    static func chargeDateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
    }

    static func billingNote(plan: PurchasePlan, product: Product, trialPeriod: Product.SubscriptionPeriod?, now: Date) -> String {
        note(plan: plan, displayPrice: product.displayPrice, pricePerPeriod: PriceFormatter.pricePerPeriod(product),
             trialText: trialPeriod.map(PriceFormatter.periodText), firstCharge: trialPeriod?.date(after: now))
    }

    /// Short fine print under the purchase button (1–2 lines; unit-tested for every language).
    /// The complete auto-renewal terms are shown under the plans (`paywall.terms.full`).
    static func note(plan: PurchasePlan, displayPrice: String, pricePerPeriod: String, trialText: String?, firstCharge: Date?) -> String {
        switch plan {
        case .lifetime:
            return L10n.tr("paywall.note.lifetime", displayPrice)
        case .yearly, .monthly:
            if let trialText, let firstCharge {
                return L10n.tr("paywall.note.trial.short", trialText, pricePerPeriod, chargeDateText(firstCharge))
            }
            return L10n.tr("paywall.note.subscription.short", pricePerPeriod)
        }
    }
}

extension Product.SubscriptionPeriod {
    /// Calendar date after this period starting at `date` (first charge after a free trial).
    func date(after date: Date, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component
        switch unit {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        @unknown default: component = .day
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date
    }
}
