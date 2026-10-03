import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var localization

    var body: some View {
        @Bindable var model = model
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DesignStates") {
                DesignStatesGallery()
            } else if model.settings.onboardingCompleted {
                MainTabView()
            } else {
                OnboardingFlow()
            }
            #else
            if model.settings.onboardingCompleted {
                MainTabView()
            } else {
                OnboardingFlow()
            }
            #endif
        }
        // Rebuild the tree when the in-app language changes so every string re-resolves.
        .id(localization.language)
        .sheet(item: $model.sheet) { sheet in
            SheetContent(sheet: sheet)
                .environment(model)
                .environment(localization)
                .environment(\.locale, localization.locale)
                // The pairing prompt must be able to appear over "Add TV" and other sheets.
                .modifier(PairingPromptModifier())
        }
        .fullScreenCover(item: Binding(get: { model.paywall.request }, set: { if $0 == nil { model.paywall.dismiss() } })) { request in
            PaywallView(request: request)
                .environment(model)
                .environment(localization)
                .environment(\.locale, localization.locale)
        }
        .overlay(alignment: .top) {
            PurchaseConfirmationBanner()
        }
        .modifier(PairingPromptModifier(isHost: { [model] in model.sheet == nil && model.paywall.request == nil }))
        .onChange(of: model.connection.pairing.prompt != .none) { _, prompting in
            // The remote's own sheets (keyboard, apps) would block the prompt.
            if prompting { model.closeLocalSheets() }
        }
        // Unrequested screens (a tapped notification, the bonus invitation) wait for a calm
        // moment and are retried whenever one of the blockers clears — never dropped.
        .onAppear { deferredPresentations() }
        .onChange(of: model.notifications.destinationSignal) { _, _ in deferredPresentations() }
        .onChange(of: model.bonus.invitationPending) { _, _ in deferredPresentations() }
        .onChange(of: model.isCalmForUnrequestedPresentation) { _, calm in
            if calm { deferredPresentations() }
        }
        .onChange(of: localization.language) { _, _ in model.languageChanged() }
    }

    private func deferredPresentations() {
        model.routePendingNotification()
        model.showBonusInvitationIfCalm()
    }
}

private struct SheetContent: View {
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .discovery:
            NavigationStack { DiscoveryView(isOnboarding: false) }
        case .compatibility:
            NavigationStack { CompatibilityView(onDone: nil) }
        case .help(let articleID):
            HelpCenterView(initialArticle: articleID) // has its own NavigationStack
        case .contactSupport(let category, let errorCode, let feature):
            NavigationStack { ContactSupportView(category: category, errorCode: errorCode, feature: feature) }
        case .remotePro:
            NavigationStack { RemoteProView() }
        case .bonus:
            NavigationStack { BonusFlowView() }
        case .introduction:
            IntroReplayView()
        case .purchaseSuccess(let plan):
            PurchaseSuccessView(plan: plan)
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            RemoteScreen()
                .tabItem { Label(L10n.tr("tab.remote"), image: "icon-remote") }
                .tag(AppModel.Tab.remote)
            CastScreen()
                .tabItem { Label(L10n.tr("tab.cast"), image: "icon-cast") }
                .tag(AppModel.Tab.cast)
            SettingsScreen()
                .tabItem { Label(L10n.tr("tab.settings"), image: "icon-settings") }
                .tag(AppModel.Tab.settings)
        }
        .task(id: model.connection.state) {
            // Offer the bonus only in a calm moment on the Remote tab.
            guard model.selectedTab == .remote, case .connected = model.connection.state else { return }
            try? await Task.sleep(for: .seconds(3))
            let calm = model.sheet == nil && model.paywall.request == nil && !model.mirroring.isActive
                && model.connection.pairing.prompt == .none && model.text.status != .sending
            await model.bonus.evaluateInvitation(isCalmMoment: calm)
        }
    }
}

/// After a verified purchase: the "You're ready to go" screen (design 20) once the paywall has
/// closed; a short banner instead if another screen is open, so nothing the user is doing closes.
private struct PurchaseConfirmationBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsBanner = false

    var body: some View {
        Group {
            if showsBanner, let plan = model.paywall.purchaseConfirmation {
                banner(plan)
            }
        }
        .onChange(of: model.paywall.purchaseConfirmation) { _, plan in
            guard let plan else { showsBanner = false; return }
            Task {
                try? await Task.sleep(for: .milliseconds(500)) // let the paywall cover finish closing
                if model.sheet == nil, model.paywall.request == nil, !model.localSheetOpen {
                    model.paywall.purchaseConfirmation = nil
                    model.sheet = .purchaseSuccess(plan)
                } else {
                    showsBanner = true
                }
            }
        }
    }

    private func banner(_ plan: PurchasePlan) -> some View {
        InlineNoticeView(kind: .success, text: L10n.tr("purchase.success.\(plan.rawValue)"))
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.xs)
                .background(Color.appBackground.opacity(0.001))
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .task {
                    Haptics.success()
                    try? await Task.sleep(for: .seconds(4))
                    model.paywall.purchaseConfirmation = nil
                    showsBanner = false
                }
                .accessibilityAddTraits(.isStaticText)
    }
}
