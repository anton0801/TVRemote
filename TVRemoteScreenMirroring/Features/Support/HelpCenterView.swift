import StoreKit
import SwiftUI

/// Help topics shown in the help center (design 25).
enum HelpTopic: String, CaseIterable, Hashable {
    case connect, remote, media, purchases, privacy

    var icon: String {
        switch self {
        case .connect: "icon-tv"
        case .remote: "icon-remote"
        case .media: "icon-photo"
        case .purchases: "creditcard"
        case .privacy: "icon-shield"
        }
    }

    var articleIDs: [HelpArticle.ID] {
        switch self {
        case .connect: ["tvNotFound", "cannotConnect"]
        case .remote: ["buttonsNotWorking", "textNotWorking", "appsNotLaunching"]
        case .media: ["mediaNotShowing", "mirroringProblem"]
        case .purchases: ["paidNoAccess", "trialOffers", "changePlan", "refund"]
        case .privacy: ["privacy"]
        }
    }

    var articles: [HelpArticle] { articleIDs.compactMap(HelpArticle.article) }
    var title: String { L10n.tr("help.topic.\(rawValue)") }
    var subtitle: String { L10n.tr("help.topic.\(rawValue).detail") }
}

enum HelpRoute: Hashable {
    case topic(HelpTopic)
    case article(HelpArticle)
}

struct HelpCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialArticle: HelpArticle.ID?
    @State private var path: [HelpRoute] = []
    @State private var query = ""

    private var searchResults: [HelpArticle] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return HelpArticle.all.filter {
            L10n.tr($0.titleKey).localizedCaseInsensitiveContains(trimmed) || L10n.tr($0.introKey).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .bottom) {
                        Text(L10n.tr("v2.help.title"))
                            .font(.appScreenTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Image(ArtAsset.connection.rawValue)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 110, height: 80)
                            .accessibilityHidden(true)
                    }
                    SearchField(text: $query, placeholder: L10n.tr("v2.help.search"))
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(HelpTopic.allCases, id: \.self) { topic in
                            NavigationLink(value: HelpRoute.topic(topic)) {
                                HelpRow(icon: topic.icon, title: topic.title, subtitle: topic.subtitle)
                            }
                            .buttonStyle(.plain)
                        }
                        SectionHeader(title: L10n.tr("v2.help.quick")).padding(.top, Spacing.xs)
                        quickFix("tvNotFound", icon: "icon-wifi-off")
                        quickFix("cannotConnect", icon: "icon-wifi", title: L10n.tr("v2.help.drops"))
                        Button {
                            model.present(.introduction)
                        } label: {
                            HelpRow(icon: "icon-play", title: L10n.tr("help.introduction"), subtitle: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("help.introduction")
                    } else if searchResults.isEmpty {
                        Text(L10n.tr("help.search.empty"))
                            .font(.appBody)
                            .foregroundStyle(Color.appTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xl)
                    } else {
                        ForEach(searchResults) { article in
                            NavigationLink(value: HelpRoute.article(article)) {
                                HelpRow(icon: article.symbol, title: L10n.tr(article.titleKey), subtitle: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.m)
                Button {
                    model.openSupport(feature: "help")
                } label: {
                    Label { Text(L10n.tr("help.contact")) } icon: { ButtonIcon("icon-mail") }
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.l)
                .accessibilityIdentifier("help.contact")
            }
            .appScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HelpRoute.self) { route in
                switch route {
                case .topic(let topic): HelpTopicView(topic: topic)
                case .article(let article): HelpArticleView(article: article)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
        }
        .onAppear {
            if let initialArticle, let article = HelpArticle.article(initialArticle), path.isEmpty { path = [.article(article)] }
        }
    }

    private func quickFix(_ id: HelpArticle.ID, icon: String, title: String? = nil) -> some View {
        Group {
            if let article = HelpArticle.article(id) {
                NavigationLink(value: HelpRoute.article(article)) {
                    HelpRow(icon: icon, title: title ?? L10n.tr(article.titleKey), subtitle: L10n.tr("help.quickFix.detail"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("help.quick.\(id)")
            }
        }
    }
}

/// Row with an amber icon, title, optional subtitle and a chevron.
struct HelpRow: View {
    let icon: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            AppIconView(icon, size: 26).foregroundStyle(Color.appAccent).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                if let subtitle {
                    Text(subtitle).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: Spacing.xs)
            AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary)
        }
        .surfaceCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s) {
                PageHeader(title: topic.title)
                ForEach(topic.articles) { article in
                    NavigationLink(value: HelpRoute.article(article)) {
                        HelpRow(icon: article.symbol, title: L10n.tr(article.titleKey), subtitle: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.m)
        }
        .appScreenBackground()
        .pageNavigation(topic.title)
    }
}

/// An article outside the help center (e.g. "How it works" in mirroring).
struct HelpArticleScreen: View {
    let articleID: HelpArticle.ID

    var body: some View {
        if let article = HelpArticle.article(articleID) {
            HelpArticleView(article: article)
        }
    }
}

/// Article (design 38): title, intro, numbered steps, its action and support.
struct HelpArticleView: View {
    @Environment(AppModel.self) private var model
    let article: HelpArticle
    @State private var showManage = false
    @State private var actionResult: String?
    @State private var isRestoring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(L10n.tr(article.titleKey))
                    .font(.appScreenTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.tr(article.introKey))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if article.id == "tvNotFound" || article.id == "cannotConnect" {
                    Image(ArtAsset.connection.rawValue)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .padding(Spacing.s)
                        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .accessibilityHidden(true)
                }
                ForEach(Array(article.stepKeys.enumerated()), id: \.offset) { index, key in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Text(verbatim: "\(index + 1)")
                            .font(.appHeadline)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.appAccent, lineWidth: 1.5))
                            .accessibilityHidden(true)
                        Text(L10n.tr(key))
                            .font(.appBody)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .surfaceCard()
                }
                if let action = article.action {
                    actionButton(action)
                }
                if let actionResult {
                    InlineNoticeView(kind: .info, text: actionResult)
                }
                Button {
                    model.openSupport(category: article.supportCategory, feature: "help")
                } label: {
                    Label { Text(L10n.tr("help.contact")) } icon: { ButtonIcon("icon-mail") }
                }
                .buttonStyle(.secondary)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .navigationTitle(L10n.tr("help.article.navTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showManage)
    }

    @ViewBuilder
    private func actionButton(_ action: HelpArticle.Action) -> some View {
        switch action {
        case .openAppSettings:
            Button(L10n.tr("action.openSettings")) { model.bonus.expectReturn(); SystemLinks.openAppSettings() }
                .buttonStyle(.primary)
        case .searchAgain:
            Button(L10n.tr("action.searchAgain")) { model.sheet = .discovery }
                .buttonStyle(.primary)
        case .restorePurchases:
            Button {
                Task {
                    isRestoring = true
                    actionResult = nil
                    model.bonus.expectReturn()
                    let result = await model.entitlements.restore()
                    isRestoring = false
                    actionResult = result.message
                }
            } label: {
                if isRestoring { ProgressView() } else { Text(L10n.tr("paywall.restore")) }
            }
            .buttonStyle(.primary)
            .disabled(isRestoring)
        case .manageSubscription:
            Button(L10n.tr("pro.manage")) { model.bonus.expectReturn(); showManage = true }
                .buttonStyle(.primary)
        case .openRemotePro:
            Button(L10n.tr("settings.remotePro")) { model.sheet = .remotePro }
                .buttonStyle(.primary)
        case .openPrivacySettings:
            NavigationLink(L10n.tr("settings.privacy")) { PrivacySettingsView() }
                .buttonStyle(.primary)
        }
    }
}
