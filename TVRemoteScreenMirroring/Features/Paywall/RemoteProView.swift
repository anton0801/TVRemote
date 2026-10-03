import StoreKit
import SwiftUI

/// Settings → Remote Pro (designs 21 subscription, 39 trial, 40 lifetime, 41 billing issue).
/// No automatic purchase on open; every date and price comes from StoreKit.
struct RemoteProView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showManage = false
    @State private var showChangePlan = false
    @State private var showOfferCodes = false
    @State private var isRestoring = false
    @State private var isChecking = false
    @State private var message: String?

    private var state: AccessState { model.entitlements.state }
    private var store: StoreService { model.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.pro.name"))
                switch state {
                case .verifying:
                    HStack(spacing: Spacing.s) { ProgressView(); Text(L10n.tr("access.verifying")).foregroundStyle(Color.appTextPrimary) }
                        .surfaceCard()
                case .inactive(let reason):
                    if reason == .billingRetry {
                        billingIssue(active: false)
                    } else {
                        inactive(reason)
                    }
                case .active(let access):
                    if access.inGracePeriod {
                        billingIssue(active: true)
                    } else if access.isLifetime {
                        lifetime(access)
                    } else if access.phase == .introductoryTrial || access.phase == .offerFreePeriod {
                        trial(access)
                    } else {
                        subscription(access)
                    }
                    if access.isFromCache {
                        InfoNote(text: L10n.tr("pro.fromCache"))
                    }
                }
                if model.entitlements.refreshFailed {
                    InlineNoticeView(kind: .warning, text: L10n.tr("pro.refreshFailed"))
                }
                if let message {
                    InlineNoticeView(kind: .info, text: message)
                }
                Text(L10n.tr("pro.sameFeatures"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.pro.name"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("common.done")) { dismiss() }
            }
        }
        .manageSubscriptionsSheet(isPresented: $showManage)
        .offerCodeRedemption(isPresented: $showOfferCodes) { _ in
            Task { await model.entitlements.refresh() }
        }
        .sheet(isPresented: $showChangePlan) {
            NavigationStack { ChangePlanView() }
        }
        .task {
            await store.loadProducts()
            await model.entitlements.refresh()
        }
        .onAppear { model.analytics.log(.changePlanOpened) }
    }

    // MARK: States

    @ViewBuilder
    private func subscription(_ access: ActiveAccess) -> some View {
        StatusBanner(icon: "crown.fill", title: L10n.tr("pro.planName.\(access.plan.rawValue)"),
                     status: L10n.tr("v2.subscription.active"), detail: L10n.tr("pro.allFeatures"))
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            groupLabel(L10n.tr("pro.yourPlan"))
            if let product = store.products[access.plan] {
                Text(PriceFormatter.pricePerPeriod(product))
                    .font(.appScreenTitle)
                    .foregroundStyle(Color.appTextPrimary)
            }
            Text(renewalLine(access))
                .font(.appBody)
                .foregroundStyle(access.willAutoRenew == false ? Color.appAccent : Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .surfaceCard()
        otherPlans(access)
        manageGroup(subscription: true)
    }

    @ViewBuilder
    private func trial(_ access: ActiveAccess) -> some View {
        StatusBanner(icon: "crown.fill", title: L10n.tr("pro.freeTrial"), status: L10n.tr("v2.subscription.active"),
                     detail: L10n.tr("pro.trialEnjoying"))
        VStack(spacing: 0) {
            DetailRow(icon: "icon-calendar", title: L10n.tr("pro.planName.\(access.plan.rawValue)"),
                      lines: [L10n.tr("pro.freeTrial"), store.products[access.plan].map { L10n.tr("pro.thenPrice", PriceFormatter.pricePerPeriod($0)) }].compactMap { $0 })
            if let end = access.expirationDate {
                SettingsDivider()
                DetailRow(icon: "icon-clock", title: L10n.tr("pro.trialEndsTitle"), lines: [format(end)])
            }
            SettingsDivider()
            if access.willAutoRenew == false {
                DetailRow(icon: "icon-refresh", title: L10n.tr("pro.renewOff"), lines: [L10n.tr("pro.renewOff.detail")])
            } else {
                DetailRow(icon: "icon-refresh", title: L10n.tr("pro.renewsAuto"), lines: [L10n.tr("pro.renewsAuto.detail")])
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
        Button { manage() } label: {
            Label { Text(L10n.tr("v2.subscription.appStore")) } icon: { ButtonIcon("icon-external-link") }
        }
        .buttonStyle(.primary)
        backToRemoteButton
        restoreLink
    }

    @ViewBuilder
    private func lifetime(_ access: ActiveAccess) -> some View {
        VStack(spacing: Spacing.xs) {
            AppIconView("icon-infinity", size: 64).foregroundStyle(Color.appAccent)
            HStack(spacing: Spacing.xs) {
                Text(L10n.tr("v2.pro.lifetimeStatus")).font(.appBannerTitle).foregroundStyle(Color.appTextPrimary)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appOnAccent, Color.appAccent)
            }
            Text(L10n.tr("v2.pro.lifetimeBody")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .surfaceCard(highlighted: true)
        .accessibilityElement(children: .combine)

        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L10n.tr("pro.allFeaturesTitle")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
            FeatureCheck(icon: "icon-tv", title: L10n.tr("pro.feature.control"), detail: L10n.tr("pro.feature.control.detail"))
            FeatureCheck(icon: "icon-photo", title: L10n.tr("v2.cast.photos"), detail: L10n.tr("pro.feature.photos.detail"))
            FeatureCheck(icon: "icon-video", title: L10n.tr("v2.cast.videos"), detail: L10n.tr("pro.feature.videos.detail"))
            FeatureCheck(icon: "icon-settings", title: L10n.tr("pro.feature.premium"), detail: L10n.tr("pro.feature.premium.detail"))
        }
        .surfaceCard()

        if let old = access.coexistingSubscription {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    AppIconView("icon-info", size: 24).foregroundStyle(Color.appTextPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("v2.pro.olderSubscription")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                        Text(old.willAutoRenew == true
                             ? L10n.tr("pro.lifetime.oldSubscriptionRenewing", L10n.tr("plan.\(old.plan.rawValue)"))
                             : (old.willAutoRenew == false ? L10n.tr("pro.lifetime.oldSubscriptionOff") : L10n.tr("pro.lifetime.oldSubscriptionUnknown")))
                            .font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if old.willAutoRenew != false {
                    Button { manage() } label: {
                        SettingsRowLabel(symbol: "icon-settings", title: L10n.tr("pro.manageExisting"))
                    }
                    .buttonStyle(.plain)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                }
            }
            .surfaceCard()
        }
        manageGroup(subscription: false)
    }

    @ViewBuilder
    private func billingIssue(active: Bool) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "crown.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.appAccent)
                .frame(width: 72, height: 72)
                .background(Color.appAccentTint, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appAccent.opacity(0.7), lineWidth: 1))
                .accessibilityHidden(true)
            Text(L10n.tr(active ? "v2.pro.accessActive" : "v2.pro.accessPaused"))
                .font(.appScreenTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
            Text(L10n.tr(active ? "pro.graceBody" : "pro.inactive.billingRetry"))
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .surfaceCard()
        HStack(alignment: .top, spacing: Spacing.s) {
            AppIconView("icon-warning", size: 28).foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("v2.pro.billingIssue")).font(.appHeadline).foregroundStyle(Color.appAccent)
                Text(L10n.tr("v2.pro.billingBody")).font(.appFootnote).foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .surfaceCard(highlighted: true)
        .accessibilityElement(children: .combine)
        Button { manage() } label: {
            Label { Text(L10n.tr("v2.subscription.appStore")) } icon: { ButtonIcon("icon-external-link") }
        }
        .buttonStyle(.primary)
        Button { Task { await checkStatus() } } label: {
            if isChecking { ProgressView() } else {
                Label { Text(L10n.tr("v2.purchase.check")) } icon: { ButtonIcon("icon-refresh") }
            }
        }
        .buttonStyle(.secondary)
        .disabled(isChecking)
        Button { model.openSupport(category: .paidNoAccess, feature: "remotePro") } label: {
            SettingsRowLabel(symbol: "icon-help", title: L10n.tr("settings.contact"))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inactive(_ reason: InactiveReason) -> some View {
        StatusBanner(icon: "crown", title: L10n.tr("v2.pro.name"), status: nil, detail: L10n.tr("pro.inactive.\(reason.rawValue)"))
        Button {
            dismiss()
            model.paywall.present(.remote)
        } label: {
            Text(L10n.tr("v2.pro.explore"))
        }
        .buttonStyle(.primary)
        manageGroup(subscription: false)
    }

    // MARK: Groups

    @ViewBuilder
    private func otherPlans(_ access: ActiveAccess) -> some View {
        let showYearly = access.plan == .monthly && access.scheduledProductID == nil && store.products[.yearly] != nil
        if showYearly || store.products[.lifetime] != nil {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                groupLabel(L10n.tr("pro.otherPlans"))
                if showYearly, let yearly = store.products[.yearly] {
                    Button { showChangePlan = true } label: {
                        DetailRow(icon: "icon-calendar", title: L10n.tr("v2.subscription.yearly"),
                                  lines: [PriceFormatter.pricePerPeriod(yearly), L10n.tr("v2.subscription.review")], chevron: true)
                            .surfaceCard(padding: 0)
                    }
                    .buttonStyle(.plain)
                }
                if let lifetime = store.products[.lifetime] {
                    VStack(spacing: Spacing.xs) {
                        Button { showChangePlan = true } label: {
                            DetailRow(icon: "icon-infinity", title: L10n.tr("v2.subscription.lifetime"),
                                      lines: [L10n.tr("pro.lifetimeOnce", lifetime.displayPrice)], chevron: true)
                        }
                        .buttonStyle(.plain)
                        InfoNote(text: L10n.tr("v2.subscription.cancelSeparate"), boxed: true)
                            .padding([.horizontal, .bottom], Spacing.s)
                    }
                    .surfaceCard(padding: 0)
                }
            }
        }
    }

    private func manageGroup(subscription: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            groupLabel(L10n.tr("pro.manageGroup"))
            VStack(spacing: 0) {
                if subscription {
                    Button { manage() } label: {
                        SettingsRowLabel(symbol: "icon-external-link", title: L10n.tr("v2.subscription.appStore"), tint: .appAccent)
                    }
                    SettingsDivider()
                }
                Button { restore() } label: {
                    HStack(spacing: 0) {
                        SettingsRowLabel(symbol: "icon-restore", title: L10n.tr("v2.action.restore"), accessory: isRestoring ? .none : .chevron, tint: .appAccent)
                        if isRestoring { ProgressView().padding(.trailing, Spacing.m) }
                    }
                }
                .disabled(isRestoring)
                SettingsDivider()
                Button { model.bonus.expectReturn(); showOfferCodes = true } label: {
                    SettingsRowLabel(symbol: "icon-gift", title: L10n.tr("pro.redeemCode"), tint: .appAccent)
                }
                SettingsDivider()
                Button { model.present(.help("paidNoAccess")) } label: {
                    SettingsRowLabel(symbol: "icon-help", title: L10n.tr("pro.purchaseHelp"), tint: .appAccent)
                }
                SettingsDivider()
                Button { backToRemote() } label: {
                    SettingsRowLabel(symbol: "icon-back", title: L10n.tr("v2.purchase.backRemote"), tint: .appAccent)
                }
            }
            .buttonStyle(.plain)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
        }
    }

    private var backToRemoteButton: some View {
        Button { backToRemote() } label: {
            HStack {
                AppIconView("icon-back", size: 22)
                Text(L10n.tr("v2.purchase.backRemote"))
                Spacer()
                AppIconView("icon-chevron-right", size: 16)
            }
        }
        .buttonStyle(.secondary)
    }

    private var restoreLink: some View {
        Button { restore() } label: {
            if isRestoring { ProgressView() } else { Text(L10n.tr("v2.action.restore")).underline() }
        }
        .font(.appSecondary)
        .foregroundStyle(Color.appTextSecondary)
        .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
        .disabled(isRestoring)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased(with: L10n.locale))
            .font(.appSectionLabel)
            .foregroundStyle(Color.appTextSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Helpers

    private func renewalLine(_ access: ActiveAccess) -> String {
        if access.willAutoRenew == false, let end = access.expirationDate {
            return L10n.tr("pro.autoRenewOff", format(end))
        }
        if let renewal = access.renewalDate ?? access.expirationDate {
            if let scheduled = access.scheduledProductID, let plan = store.plan(for: scheduled) {
                let price = store.products[plan].map(PriceFormatter.pricePerPeriodSentence) ?? ""
                return L10n.tr("pro.scheduledChange", L10n.tr("plan.\(plan.rawValue)"), format(renewal), price)
            }
            return L10n.tr("v2.subscription.renews", format(renewal))
        }
        return L10n.tr("pro.renewalUnknown")
    }

    private func manage() {
        model.bonus.expectReturn()
        model.analytics.log(.subscriptionManagementOpened)
        showManage = true
    }

    private func restore() {
        Task {
            isRestoring = true
            model.bonus.expectReturn()
            let result = await model.entitlements.restore()
            isRestoring = false
            message = result.message
        }
    }

    private func checkStatus() async {
        isChecking = true
        await model.entitlements.refresh()
        isChecking = false
    }

    private func backToRemote() {
        model.selectedTab = .remote
        dismiss()
    }

    private func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
    }
}

/// Amber-bordered status card with a crown tile ("Monthly plan · Active").
private struct StatusBanner: View {
    let icon: String
    let title: String
    let status: String?
    let detail: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.appAccent)
                .frame(width: 52, height: 52)
                .background(Color.appBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appAccent.opacity(0.7), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let status {
                    (Text(title).foregroundStyle(Color.appTextPrimary) + Text(verbatim: " · ") .foregroundStyle(Color.appTextPrimary)
                        + Text(status).foregroundStyle(Color.appAccent))
                        .font(.appHeadline)
                } else {
                    Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                }
                Text(detail).font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .surfaceCard(highlighted: true)
        .accessibilityElement(children: .combine)
    }
}

/// Icon, title and one or more secondary lines; optional chevron.
private struct DetailRow: View {
    let icon: String
    let title: String
    let lines: [String]
    var chevron = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            AppIconView(icon, size: 26).foregroundStyle(Color.appAccent).frame(width: 40, height: 40)
                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if chevron { AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary) }
        }
        .padding(Spacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct FeatureCheck: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            AppIconView(icon, size: 24).foregroundStyle(Color.appTextPrimary).frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.appBody).foregroundStyle(Color.appTextPrimary)
                Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appOnAccent, Color.appAccent).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Month → year and subscription → lifetime (spec §33). Uses Apple's rules; no own proration.
struct ChangePlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @State private var result: String?
    @State private var showLifetimeNote = false

    private var store: StoreService { model.store }
    private var access: ActiveAccess? { model.entitlements.state.activeAccess }
    private var isBlocked: Bool { store.purchaseInProgress != nil || !model.entitlements.pendingProductIDs.isEmpty }

    var body: some View {
        List {
            if let yearly = store.products[.yearly], access?.plan == .monthly, access?.scheduledProductID == nil {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(PriceFormatter.pricePerPeriod(yearly)).font(.appSectionTitle)
                        if let monthly = store.products[.monthly], let savings = PriceFormatter.yearlySavings(monthly: monthly, yearly: yearly) {
                            Text(L10n.tr("change.yearly.savings", yearly.displayPrice, savings.amount, monthly.displayPrice, savings.percent))
                                .font(.appSecondary)
                            Text(L10n.tr("change.yearly.monthlyEquivalent", PriceFormatter.monthlyEquivalent(of: yearly)))
                                .font(.appFootnote)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        Text(L10n.tr(access?.phase == .standard ? "change.yearly.timing" : "change.yearly.timingTrial"))
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Button(L10n.tr("change.yearly.confirm")) {
                        Task { await change(to: .yearly) }
                    }
                    .buttonStyle(.primary)
                    .disabled(isBlocked)
                } header: {
                    SectionHeader(title: L10n.tr("plan.yearly"))
                }
            }
            if let lifetime = store.products[.lifetime], access?.isLifetime == false {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(lifetime.displayPrice).font(.appSectionTitle)
                        Text(L10n.tr("change.lifetime.detail")).font(.appSecondary)
                        Text(L10n.tr("paywall.lifetime.note")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                    }
                    Button(L10n.tr("paywall.cta.lifetime")) { showLifetimeNote = true }
                        .buttonStyle(.primary)
                        .disabled(isBlocked)
                } header: {
                    SectionHeader(title: L10n.tr("plan.lifetime"))
                }
            }
            if !model.entitlements.pendingProductIDs.isEmpty {
                // Ask to Buy waiting for approval: a second request would duplicate it.
                Section { InlineNoticeView(kind: .info, text: L10n.tr("purchase.pending")) }.listRowBackground(Color.clear)
            }
            if let result {
                Section { InlineNoticeView(kind: .info, text: result) }.listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .appScreenBackground()
        .navigationTitle(L10n.tr("change.title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("common.close")) { dismiss() }
            }
        }
        .alert(L10n.tr("paywall.lifetime.noteTitle"), isPresented: $showLifetimeNote) {
            Button(L10n.tr("paywall.lifetime.continue")) { Task { await change(to: .lifetime) } }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("paywall.lifetime.note"))
        }
    }

    private func change(to plan: PurchasePlan) async {
        model.analytics.log(.planChangeRequested(plan: plan.analyticsPlan))
        model.bonus.expectReturn()
        let outcome = await store.purchase(plan, using: purchase)
        await model.entitlements.refresh()
        switch outcome {
        case .success:
            model.analytics.log(.planChangeConfirmed(plan: plan.analyticsPlan))
            if plan == .yearly {
                // Apple applies a same-level change of duration at the next renewal.
                result = model.entitlements.state.activeAccess?.scheduledProductID != nil
                    ? L10n.tr("change.yearly.scheduled") : L10n.tr("change.yearly.syncing")
            } else {
                result = L10n.tr("change.lifetime.done")
            }
        case .pending:
            result = L10n.tr("purchase.pending")
        case .cancelled:
            result = nil // original plan stays active
        case .failed(let error):
            result = error.localizedMessage
        }
    }
}
