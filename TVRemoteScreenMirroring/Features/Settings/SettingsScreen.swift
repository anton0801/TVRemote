import SwiftUI

/// Settings (design 22): Remote Pro banner, Application, Preferences, Support, About.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var localization
    @Environment(\.openURL) private var openURL
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ScreenHeader(title: L10n.tr("tab.settings"))
                    RemoteProBanner()

                    SettingsGroup(title: L10n.tr("settings.group.app")) {
                        NavigationLink {
                            SavedTVsView()
                        } label: {
                            SettingsRowLabel(symbol: "icon-tv", title: L10n.tr("v2.settings.savedTVs"), subtitle: L10n.tr("settings.savedTVs.detail"),
                                             value: model.devices.devices.isEmpty ? nil : "\(model.devices.devices.count)")
                        }
                        .accessibilityIdentifier("settings.savedTVs")
                        SettingsDivider()
                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            SettingsRowLabel(symbol: "icon-globe", title: L10n.tr("v2.settings.language"), subtitle: languageName)
                        }
                        .accessibilityIdentifier("settings.language")
                        SettingsDivider()
                        SettingsToggleRow(symbol: "icon-haptics", title: L10n.tr("v2.settings.haptics"), detail: L10n.tr("settings.haptics.detail"),
                                          isOn: Binding(get: { model.settings.hapticsEnabled }, set: {
                                              model.settings.hapticsEnabled = $0
                                              Haptics.isEnabled = $0
                                          }), tiled: false)
                    }

                    SettingsGroup(title: L10n.tr("settings.group.preferences")) {
                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            SettingsRowLabel(symbol: "icon-bell", title: L10n.tr("v2.settings.notifications"), subtitle: notificationsSummary)
                        }
                        .accessibilityIdentifier("settings.notifications")
                        SettingsDivider()
                        NavigationLink {
                            PrivacySettingsView()
                        } label: {
                            SettingsRowLabel(symbol: "icon-shield", title: L10n.tr("settings.privacy"), subtitle: privacySummary)
                        }
                        .accessibilityIdentifier("settings.privacy")
                    }

                    SettingsGroup(title: L10n.tr("settings.group.support")) {
                        Button { model.sheet = .help(nil) } label: {
                            SettingsRowLabel(symbol: "icon-help", title: L10n.tr("v2.settings.help"), subtitle: L10n.tr("settings.help.detail"))
                        }
                        .accessibilityIdentifier("settings.help")
                        SettingsDivider()
                        Button { model.openSupport() } label: {
                            SettingsRowLabel(symbol: "icon-mail", title: L10n.tr("settings.contact"), subtitle: L10n.tr("settings.contact.detail"))
                        }
                        .accessibilityIdentifier("settings.contact")
                        SettingsDivider()
                        Button { restore() } label: {
                            HStack(spacing: 0) {
                                SettingsRowLabel(symbol: "icon-restore", title: L10n.tr("v2.action.restore"), subtitle: L10n.tr("settings.restore.detail"),
                                                 accessory: isRestoring ? .none : .chevron)
                                if isRestoring { ProgressView().padding(.trailing, Spacing.m) }
                            }
                        }
                        .disabled(isRestoring)
                        .accessibilityIdentifier("settings.restore")
                        if model.bonus.isCampaignConfigured {
                            SettingsDivider()
                            Button { model.sheet = .bonus } label: {
                                SettingsRowLabel(symbol: "icon-gift", title: L10n.tr("settings.offers"))
                            }
                        }
                    }
                    if let restoreMessage {
                        InlineNoticeView(kind: .info, text: restoreMessage, actionTitle: L10n.tr("common.dismiss")) { self.restoreMessage = nil }
                    }

                    SettingsGroup(title: L10n.tr("v2.settings.about")) {
                        Button { openURL(model.configuration.termsURL) } label: {
                            SettingsRowLabel(symbol: "icon-document", title: L10n.tr("v2.legal.termsFull"), subtitle: L10n.tr("settings.terms.detail"), accessory: .external)
                        }
                        if let privacy = model.configuration.privacyURL {
                            SettingsDivider()
                            Button { openURL(privacy) } label: {
                                SettingsRowLabel(symbol: "icon-shield", title: L10n.tr("v2.privacy.policy"), subtitle: L10n.tr("settings.privacyPolicy.detail"), accessory: .external)
                            }
                        }
                    }

                    VStack(spacing: Spacing.xxs) {
                        Text(verbatim: "TV Remote · \(L10n.tr("settings.versionLine", Self.version))")
                        Text(L10n.tr("settings.independentNote"))
                            .multilineTextAlignment(.center)
                    }
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Spacing.m)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.xs)
            }
            .buttonStyle(.plain)
            .appScreenBackground()
            .statusBarBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.notifications.refreshAuthorization() }
        }
    }

    private var languageName: String {
        localization.language == .system
            ? L10n.tr("settings.language.systemValue", AppLanguage(rawValue: localization.effectiveCode)?.endonym ?? "")
            : localization.language.endonym
    }

    private var notificationsSummary: String {
        let enabled = [model.settings.trialReminderEnabled, model.settings.serviceNotificationsEnabled, model.settings.marketingNotificationsConsent.isGranted]
            .filter { $0 }.count
        if model.notifications.permission == .denied { return L10n.tr("notifications.summary.off") }
        return enabled == 0 ? L10n.tr("notifications.summary.none") : L10n.tr("notifications.summary.count", enabled)
    }

    private var privacySummary: String {
        model.settings.analyticsConsent.isGranted || model.settings.crashReportsConsent.isGranted
            ? L10n.tr("privacy.summary.sharing") : L10n.tr("privacy.summary.notSharing")
    }

    private func restore() {
        isRestoring = true
        restoreMessage = nil
        model.bonus.expectReturn()
        Task {
            let result = await model.entitlements.restore()
            isRestoring = false
            restoreMessage = result.message
            if let message = result.message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Saved TVs (design 26)

struct SavedTVsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: TVDevice?
    @State private var newName = ""
    @State private var forgetting: TVDevice?
    @State private var pendingSwitch: PendingTVSwitch?

    private func use(_ device: TVDevice) {
        let connect: @MainActor () -> Void = { [model] in model.connection.connect(to: device) }
        if model.requestConnection(to: device.id, connect: connect) == .needsConfirmation {
            pendingSwitch = PendingTVSwitch(connect: connect)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.settings.savedTVs"))
                if model.devices.devices.isEmpty {
                    StateMessageView(art: ArtAsset.connection.rawValue, title: L10n.tr("saved.empty.title"), message: L10n.tr("saved.empty.message"))
                }
                ForEach(model.devices.devices) { device in
                    card(device)
                }
                Button {
                    model.sheet = .discovery
                } label: {
                    Label { Text(L10n.tr("v2.tv.add")) } icon: { ButtonIcon("icon-plus") }
                }
                .buttonStyle(.outline)
                Text(L10n.tr("v2.tv.local"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.settings.savedTVs"))
        .alert(L10n.tr("saved.rename.title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.tr("saved.rename.placeholder"), text: $newName)
            Button(L10n.tr("common.save")) {
                if let renaming { model.devices.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) { renaming = nil }
        } message: {
            Text(L10n.tr("saved.rename.message"))
        }
        .confirmationDialog(L10n.tr("saved.forget.title"), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("saved.forget"), role: .destructive) {
                if let forgetting { model.forgetTV(forgetting.id) }
                forgetting = nil
            }
        } message: {
            Text(L10n.tr("saved.forget.message"))
        }
        .modifier(SwitchTVConfirmation(pending: $pendingSwitch))
    }

    private func card(_ device: TVDevice) -> some View {
        let isCurrent = device.id == model.devices.selectedDeviceID
        let status = isCurrent ? TVConnectionStatus.of(device, in: model.connection.state)
                               : TVConnectionStatus(text: L10n.tr("v2.status.offline"), tone: .neutral)
        let connected = isCurrent && model.connection.state.isConnected
        return VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                AppIconView("icon-tv", size: 40)
                    .foregroundStyle(Color.appTextPrimary)
                    .frame(width: 64, height: 64)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.appBannerTitle).foregroundStyle(Color.appTextPrimary)
                    Text([device.platform.shortName, device.modelName].compactMap { $0 }.joined(separator: " · "))
                        .font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                    HStack(spacing: 6) {
                        Circle().fill(status.dotColor).frame(width: 8, height: 8)
                        Text(status.text).font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                    }
                    if device.customName != nil {
                        Text(L10n.tr("saved.reportedName", device.reportedName))
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if !connected {
                Button {
                    use(device)
                } label: {
                    Label { Text(L10n.tr("v2.action.connect")) } icon: { ButtonIcon("icon-power") }
                }
                .buttonStyle(.outline)
                .accessibilityHint(L10n.tr("device.connect.hint"))
            }
            HStack(spacing: Spacing.xs) {
                Button {
                    newName = device.customName ?? device.reportedName
                    renaming = device
                } label: {
                    Label { Text(L10n.tr("v2.tv.rename")) } icon: { ButtonIcon("icon-edit") }
                }
                .buttonStyle(.secondary)
                Button {
                    forgetting = device
                } label: {
                    Label { Text(L10n.tr("v2.tv.forget")) } icon: { ButtonIcon("icon-trash") }
                        .foregroundStyle(Color.appDanger)
                }
                .buttonStyle(.secondary)
            }
        }
        .surfaceCard()
    }
}

// MARK: - Language (design 32)

struct LanguageSettingsView: View {
    @Environment(LocalizationManager.self) private var localization

    /// Decorative only (a language is not a country); VoiceOver reads the language name.
    private static let flags: [AppLanguage: String] = [.en: "🇺🇸", .es: "🇪🇸", .ru: "🇷🇺", .de: "🇩🇪", .fr: "🇫🇷"]

    private var effective: AppLanguage { AppLanguage(rawValue: localization.effectiveCode) ?? .en }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.settings.language"))
                VStack(spacing: 0) {
                    ForEach(Array(AppLanguage.allCases.filter { $0 != .system }.enumerated()), id: \.element) { index, language in
                        if index > 0 { SettingsDivider() }
                        let selected = language == effective
                        Button {
                            Haptics.selection()
                            localization.setLanguage(language)
                        } label: {
                            HStack(spacing: Spacing.m) {
                                Text(verbatim: Self.flags[language] ?? "").font(.title2).accessibilityHidden(true)
                                Text(verbatim: language.endonym).font(.appBody).foregroundStyle(Color.appTextPrimary)
                                Spacer()
                                if selected {
                                    AppIconView("icon-check-circle", size: 24).foregroundStyle(Color.appAccent)
                                } else {
                                    RadioIndicator(isOn: false)
                                }
                            }
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: HitTarget.row)
                            .background(selected ? Color.appAccentTint : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))

                Toggle(isOn: Binding(get: { localization.language == .system }, set: { useSystem in
                    localization.setLanguage(useSystem ? .system : effective)
                })) {
                    Text(L10n.tr("v2.settings.systemLanguage")).font(.appBody).foregroundStyle(Color.appTextPrimary)
                }
                .tint(Color.appAccent)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: HitTarget.row)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))

                InfoNote(text: L10n.tr("v2.settings.priceRegion"))
                InfoNote(text: L10n.tr("settings.language.footer"))
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.settings.language"))
    }
}

// MARK: - Privacy (design 33)

struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmClear = false
    @State private var cleared = false
    @State private var showDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                PageHeader(title: L10n.tr("settings.privacy"))
                Text(L10n.tr("v2.privacy.intro"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.bottom, Spacing.xxs)
                card {
                    SettingsToggleRow(symbol: "chart.bar", title: L10n.tr("v2.privacy.analytics"), detail: L10n.tr("privacy.analytics.footer"),
                                      isOn: Binding(get: { model.settings.analyticsConsent.isGranted }, set: { model.setAnalyticsConsent($0 ? .granted : .denied) }))
                        .accessibilityIdentifier("privacy.analytics")
                }
                card {
                    SettingsToggleRow(symbol: "icon-document", title: L10n.tr("v2.privacy.crashes"), detail: L10n.tr("privacy.crash.footer"),
                                      isOn: Binding(get: { model.settings.crashReportsConsent.isGranted }, set: { model.setCrashConsent($0 ? .granted : .denied) }))
                        .accessibilityIdentifier("privacy.crashes")
                }
                card {
                    // The same setting as "Offers & discounts" in Notifications.
                    NotificationCategoryToggle(category: .offers, symbol: "tag", title: L10n.tr("v2.notifications.offers"),
                                               detail: L10n.tr("v2.notifications.offers.body"))
                }
                InfoNote(text: L10n.tr("v2.privacy.noContent"))
                    .padding(.vertical, Spacing.xs)
                if !FirebaseBootstrap.isConfigured {
                    InfoNote(text: L10n.tr("privacy.firebaseNotConfigured"))
                }
                card {
                    if let privacy = model.configuration.privacyURL {
                        Button { openURL(privacy) } label: {
                            SettingsRowLabel(symbol: "icon-document", title: L10n.tr("v2.privacy.policy"), accessory: .external, tint: .appAccent)
                        }
                        .buttonStyle(.plain)
                        SettingsDivider()
                    }
                    Button { showDiagnostics = true } label: {
                        SettingsRowLabel(symbol: "icon-search", title: L10n.tr("privacy.reviewDiagnostics"), tint: .appAccent)
                    }
                    .buttonStyle(.plain)
                }
                SettingsGroup(title: L10n.tr("privacy.onDevice"), footer: L10n.tr("privacy.deletion.footer")) {
                    Text(L10n.tr("privacy.summary"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsDivider()
                    Button(role: .destructive) { confirmClear = true } label: {
                        SettingsRowLabel(symbol: "icon-trash", title: L10n.tr("privacy.clearDiagnostics"), accessory: .none, tint: .appDanger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, Spacing.s)
                if cleared {
                    StatusBadge(kind: .ready, text: L10n.tr("privacy.clearDiagnostics.done"))
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("settings.privacy"))
        .confirmationDialog(L10n.tr("privacy.clearDiagnostics.confirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L10n.tr("privacy.clearDiagnostics"), role: .destructive) {
                DiagnosticsLog.shared.clear()
                cleared = true
                AccessibilityNotification.Announcement(L10n.tr("privacy.clearDiagnostics.done")).post()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsLogView()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
    }
}

/// What the technical log on this device contains (read-only, newest first).
private struct DiagnosticsLogView: View {
    @Environment(\.dismiss) private var dismiss

    private var lines: [String] {
        DiagnosticsLog.shared.recentEntries(limit: 200).reversed().map { entry in
            let time = entry.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
            return [time, entry.event.rawValue, entry.platform?.rawValue, entry.errorCode].compactMap { $0 }.joined(separator: "  ")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(L10n.tr("support.diagnostics.excluded"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.bottom, Spacing.xs)
                    if lines.isEmpty {
                        Text(L10n.tr("privacy.diagnostics.empty")).font(.appBody).foregroundStyle(Color.appTextSecondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.footnote.monospaced()).foregroundStyle(Color.appTextPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.screen)
            }
            .appScreenBackground()
            .navigationTitle(L10n.tr("privacy.reviewDiagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common.done")) { dismiss() } }
            }
        }
    }
}
