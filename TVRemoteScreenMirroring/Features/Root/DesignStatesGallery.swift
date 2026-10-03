#if DEBUG
import SwiftUI

/// DEBUG only (`-DesignStates`): states that need a real TV or App Store answer, shown with
/// placeholder actions for visual QA. Nothing here reaches release builds.
struct DesignStatesGallery: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Purchase pending (30)") {
                    PaywallStateScreen(close: {}, art: ArtAsset.pending.rawValue, systemIcon: nil,
                                       title: L10n.tr("v2.purchase.pending"), message: L10n.tr("v2.purchase.pending.body"),
                                       note: L10n.tr("purchase.pending.note")) {
                        Button(L10n.tr("v2.purchase.check")) {}.buttonStyle(.primary)
                        Button(L10n.tr("v2.action.close")) {}.buttonStyle(.secondary)
                    }
                    .appScreenBackground()
                }
                .accessibilityIdentifier("states.pending")
                NavigationLink("Plans unavailable (34)") {
                    PaywallStateScreen(close: {}, art: nil, systemIcon: "bag.badge.questionmark",
                                       title: L10n.tr("v2.purchase.unavailable"), message: L10n.tr("v2.purchase.unavailable.body")) {
                        Button(L10n.tr("v2.action.retry")) {}.buttonStyle(.primary)
                        Button(L10n.tr("v2.purchase.without")) {}.buttonStyle(.secondary)
                    }
                    .appScreenBackground()
                }
                .accessibilityIdentifier("states.unavailable")
                NavigationLink("Purchase not completed (43)") {
                    PaywallStateScreen(close: {}, art: ArtAsset.connectionLost.rawValue, systemIcon: nil,
                                       title: L10n.tr("v2.purchase.unconfirmed"), message: L10n.tr("v2.purchase.unconfirmedBody")) {
                        Button(L10n.tr("v2.purchase.checkStatus")) {}.buttonStyle(.primary)
                        Button(L10n.tr("v2.purchase.backPlans")) {}.buttonStyle(.secondary)
                    }
                    .appScreenBackground()
                }
                .accessibilityIdentifier("states.unconfirmed")
                NavigationLink("No TV found (28)") {
                    ScrollView { NoTVFoundView(onSearch: {}).padding(Spacing.screen) }.appScreenBackground()
                }
                .accessibilityIdentifier("states.noTV")
                NavigationLink("Local network blocked (29)") {
                    ScrollView { NetworkBlockedView().padding(Spacing.screen) }.appScreenBackground()
                }
                .accessibilityIdentifier("states.network")
                NavigationLink("Purchase success (20)") { PurchaseSuccessView(plan: .yearly) }
                    .accessibilityIdentifier("states.success")
                NavigationLink("Mirroring quality (45)") { MirroringQualityView() }
                    .accessibilityIdentifier("states.quality")
            }
            .scrollContentBackground(.hidden)
            .appScreenBackground()
            .navigationTitle("Design states")
        }
    }
}
#endif
