import SwiftUI

/// All TV apps (design 11): search, grid of logo cards (favorites starred), honest footer.
struct TVAppsView: View {
    @Environment(AppModel.self) private var model
    @State private var showReorder = false
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.xs, alignment: .top), count: 3)

    private var filtered: [TVAppsController.Item] {
        let items = model.apps.items
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Favorites first, in their order; then the rest.
            let favorites = model.apps.favorites
            return favorites + items.filter { !model.apps.isFavorite($0) }
        }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        let apps = model.apps
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.apps.title"))
                if let device = model.devices.selectedDevice {
                    Label {
                        Text(device.displayName)
                    } icon: {
                        AppIconView("icon-tv", size: 22)
                    }
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                }
                if !model.connection.state.isConnected {
                    StateMessageView(art: ArtAsset.connectionLost.rawValue, title: L10n.tr("apps.notConnected.title"),
                                     message: L10n.tr("apps.notConnected.message"))
                        .frame(maxWidth: .infinity)
                } else {
                    SearchField(text: $query, placeholder: L10n.tr("v2.apps.search"))
                    AppLaunchStatusView()
                    if filtered.isEmpty {
                        Text(L10n.tr("apps.search.empty"))
                            .font(.appBody)
                            .foregroundStyle(Color.appTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Spacing.xl)
                    } else {
                        LazyVGrid(columns: columns, spacing: Spacing.xs) {
                            ForEach(filtered) { AppTile(item: $0, layout: .card) }
                        }
                    }
                    Text(apps.isCatalog ? L10n.tr("apps.catalog.footer") : L10n.tr("v2.apps.note"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.s)
                    Text(L10n.tr("apps.favorites.footer"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.apps.title"))
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.tr("apps.reorder")) { showReorder = true }
                    .disabled(!model.connection.state.isConnected)
            }
        }
        .sheet(isPresented: $showReorder) {
            NavigationStack { FavoritesEditor() }
        }
        .onChange(of: showReorder) { _, open in model.localSheetOpen = open }
        .onChange(of: model.closeLocalSheetsSignal) { _, _ in showReorder = false }
    }
}

/// Rounded search field in the kit style.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            AppIconView("icon-search", size: 22).foregroundStyle(Color.appTextSecondary)
            TextField(text: $text) {
                Text(placeholder).foregroundStyle(Color.appTextSecondary)
            }
            .font(.appBody)
            .foregroundStyle(Color.appTextPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.appTextSecondary)
                }
                .accessibilityLabel(L10n.tr("common.clear"))
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 52)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
    }
}

/// Reorder / add / remove quick-launch apps.
private struct FavoritesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let apps = model.apps
        List {
            Section {
                ForEach(apps.favorites) { item in
                    Text(item.title).font(.appBody)
                }
                .onMove { apps.moveFavorites(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets { apps.toggleFavorite(apps.favorites[index]) }
                }
            } header: {
                Text(L10n.tr("apps.favorites"))
            } footer: {
                Text(L10n.tr("apps.favorites.footer"))
            }
            Section {
                ForEach(apps.items.filter { !apps.isFavorite($0) }) { item in
                    Button {
                        apps.toggleFavorite(item)
                    } label: {
                        Label(item.title, systemImage: "plus.circle")
                            .font(.appBody)
                            .foregroundStyle(Color.appTextPrimary)
                    }
                    .accessibilityLabel(L10n.tr("apps.favorite", item.title))
                }
            } header: {
                Text(apps.isCatalog ? L10n.tr("apps.catalog") : L10n.tr("apps.installed"))
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .appScreenBackground()
        .navigationTitle(L10n.tr("apps.reorder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("common.done")) { dismiss() }
            }
        }
    }
}

/// Honest launch result: "opened" only when the TV confirmed it.
struct AppLaunchStatusView: View {
    @Environment(AppModel.self) private var model

    private func title(_ id: String) -> String {
        model.apps.items.first { $0.id == id }?.title ?? id
    }

    var body: some View {
        switch model.apps.launchStatus {
        case .idle, .launching:
            EmptyView()
        case .opened(let id):
            InlineNoticeView(kind: .success, text: L10n.tr("apps.status.opened", title(id)))
        case .sent(let id):
            InlineNoticeView(kind: .info, text: L10n.tr("apps.status.sent", title(id)))
        case .failed(let id, let error):
            InlineNoticeView(kind: .warning, text: L10n.tr("apps.status.failed", title(id)) + " " + error.localizedMessage,
                             actionTitle: L10n.tr("apps.openHome")) {
                model.sendCommand(.home)
            }
        }
    }
}
