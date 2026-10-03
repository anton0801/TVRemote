import StoreKit
import SwiftUI

/// After a verified purchase (design 20). Shows only what StoreKit confirmed: the plan, the
/// trial if one is running, the price after it. Sharing never starts from here.
struct PurchaseSuccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: PurchasePlan
    @State private var showManage = false

    private var access: ActiveAccess? { model.entitlements.state.activeAccess }
    private var product: Product? { model.store.products[plan] }
    private var isTrial: Bool { access?.phase == .introductoryTrial || access?.phase == .offerFreePeriod }

    private var subtitle: String {
        if isTrial, let period = product?.subscription?.introductoryOffer?.period {
            return L10n.tr("purchase.success.trialActive", PriceFormatter.periodText(period))
        }
        return L10n.tr("purchase.success.active")
    }

    private var priceLine: String? {
        guard let product else { return nil }
        if plan == .lifetime { return L10n.tr("v2.plan.once") }
        let price = PriceFormatter.pricePerPeriod(product)
        return isTrial ? L10n.tr("purchase.success.afterTrial", price) : price
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    Image(ArtAsset.success.rawValue)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 200)
                        .accessibilityHidden(true)
                    Text(L10n.tr("v2.purchase.success"))
                        .font(.appScreenTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                    HStack(alignment: .top, spacing: Spacing.m) {
                        AppIconView(plan == .lifetime ? "icon-infinity" : "icon-calendar", size: 28)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 52, height: 52)
                            .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("pro.planName.\(plan.rawValue)")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                            if let priceLine {
                                Text(priceLine).font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                            }
                            if plan != .lifetime {
                                Text(L10n.tr("purchase.success.manageNote")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .surfaceCard()
                    .accessibilityElement(children: .combine)
                    Button(L10n.tr("v2.purchase.backRemote")) {
                        model.selectedTab = .remote
                        dismiss()
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("purchase.backToRemote")
                    if plan != .lifetime {
                        Button(L10n.tr("v2.subscription.manage")) {
                            model.bonus.expectReturn()
                            showManage = true
                        }
                        .buttonStyle(.secondary)
                    }
                    InfoNote(text: L10n.tr("purchase.success.sharingNote"))
                        .padding(.top, Spacing.xs)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.l)
            }
            .appScreenBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("v2.action.done")) { dismiss() }
                }
            }
            .manageSubscriptionsSheet(isPresented: $showManage)
        }
        .task { Haptics.success() }
    }
}
