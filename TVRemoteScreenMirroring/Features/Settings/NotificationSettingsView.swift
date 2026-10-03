import SwiftUI
import UserNotifications

/// Notifications (design 23; 36 when iOS blocks them). Switches reflect real states — the iOS
/// permission, the saved choice and remote registration are separate.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var notifications: NotificationService { model.notifications }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                PageHeader(title: L10n.tr("v2.settings.notifications"))
                statusBlock
                if notifications.permission == .denied {
                    Text(L10n.tr("notifications.types"))
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .padding(.top, Spacing.xs)
                }
                card {
                    NotificationCategoryToggle(category: .service, symbol: "icon-settings", title: L10n.tr("v2.notifications.service"),
                                               detail: detail(L10n.tr("v2.notifications.service.body")))
                }
                card {
                    NotificationCategoryToggle(category: .offers, symbol: "tag", title: L10n.tr("v2.notifications.offers"),
                                               detail: detail(L10n.tr("v2.notifications.offers.body")))
                }
                card {
                    NotificationCategoryToggle(category: .trialReminder, symbol: "icon-clock", title: L10n.tr("v2.notifications.reminder"),
                                               detail: detail(L10n.tr("v2.notifications.reminder.body")))
                }
                if notifications.permission == .denied {
                    Button { dismiss() } label: { Text(L10n.tr("v2.action.notNow")) }
                        .buttonStyle(.secondary)
                        .padding(.top, Spacing.xs)
                    Text(L10n.tr("notifications.offersOptional"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(maxWidth: .infinity)
                } else {
                    card {
                        Button {
                            model.bonus.expectReturn()
                            SystemLinks.openAppSettings()
                        } label: {
                            SettingsRowLabel(symbol: "icon-settings", title: L10n.tr("notifications.openIOSSettings"),
                                             subtitle: L10n.tr("notifications.openIOSSettings.detail"))
                        }
                        .buttonStyle(.plain)
                    }
                    Text(L10n.tr("v2.notifications.change") + " " + L10n.tr("notifications.marketing.footer"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                syncStatus
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.settings.notifications"))
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from iOS Settings: read the permission again.
            if phase == .active { Task { await notifications.refreshAuthorization() } }
        }
    }

    /// While iOS blocks notifications, every type explains why its switch is off.
    private func detail(_ text: String) -> String {
        notifications.permission == .denied ? L10n.tr("v2.notifications.after") : text
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
    }

    // MARK: Status

    @ViewBuilder
    private var statusBlock: some View {
        switch notifications.permission {
        case .denied:
            VStack(spacing: Spacing.s) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(Color.appSurfaceRaised))
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.appOnAccent, Color.appAccent)
                }
                .accessibilityHidden(true)
                Text(L10n.tr("v2.notifications.blocked"))
                    .font(.appBannerTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.tr("v2.notifications.enable"))
                    .font(.appSecondary)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.bonus.expectReturn()
                    SystemLinks.openAppSettings()
                } label: {
                    Label { Text(L10n.tr("v2.action.openSettings")) } icon: { ButtonIcon("icon-settings") }
                }
                .buttonStyle(.outline)
                .padding(.top, Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
            .surfaceCard()
        case .allowed:
            statusRow(dot: .appSuccess, title: L10n.tr("v2.notifications.allowed"), detail: L10n.tr("notifications.status.allowed"))
        case .provisional:
            statusRow(dot: .appAccent, title: L10n.tr("v2.settings.notifications"), detail: L10n.tr("notifications.status.provisional"))
        case .notAsked:
            statusRow(dot: .appTextSecondary, title: L10n.tr("v2.settings.notifications"), detail: L10n.tr("notifications.status.notAsked"))
        }
    }

    private func statusRow(dot: Color, title: String, detail: String?) -> some View {
        HStack(spacing: Spacing.m) {
            AppIconView("icon-bell", size: 28).foregroundStyle(Color.appTextPrimary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                if let detail {
                    Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch notifications.syncState {
        case .idle, .synced:
            EmptyView()
        case .syncing:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("notifications.sync.syncing")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
            }
        case .notConfigured:
            InlineNoticeView(kind: .info, text: L10n.tr("notifications.sync.notConfigured"))
        case .pending:
            InlineNoticeView(kind: .info, text: L10n.tr("notifications.sync.pending"), actionTitle: L10n.tr("action.retry")) {
                Task { await notifications.retryPendingSync() }
            }
        case .failed:
            InlineNoticeView(kind: .warning, text: L10n.tr("notifications.sync.failed"), actionTitle: L10n.tr("action.retry")) {
                Task { await notifications.retryPendingSync() }
            }
        }
    }
}

/// One notification category switch. Used on Notifications and (for offers) on Privacy, so
/// both show and change the same setting.
struct NotificationCategoryToggle: View {
    @Environment(AppModel.self) private var model
    let category: NotificationCategory
    let symbol: String
    let title: String
    let detail: String
    @State private var explainFirst = false
    @State private var busy = false
    /// Value shown while a change is being applied, so the switch doesn't bounce back.
    @State private var optimistic: Bool?

    private var notifications: NotificationService { model.notifications }

    private var stored: Bool {
        switch category {
        case .trialReminder: model.settings.trialReminderEnabled
        case .service: model.settings.serviceNotificationsEnabled
        case .offers: model.settings.marketingNotificationsConsent.isGranted
        }
    }

    var body: some View {
        let shown = optimistic ?? stored
        SettingsToggleRow(
            symbol: symbol, title: title, detail: detail,
            isOn: Binding(get: { shown }, set: { newValue in
                if newValue, notifications.permission == .notAsked {
                    explainFirst = true // explain first, then the system prompt
                } else {
                    toggle(to: newValue)
                }
            }),
            // Turning off (withdrawing) always works; turning on needs the iOS permission.
            isEnabled: !busy && (stored || notifications.permission.allowsToggling)
        )
        .accessibilityIdentifier("notifications.\(category)")
        .alert(L10n.tr("notifications.prompt.title"), isPresented: $explainFirst) {
            Button(L10n.tr("notifications.prompt.continue")) { toggle(to: true) }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("notifications.prompt.message"))
        }
    }

    private func toggle(to value: Bool) {
        busy = true
        optimistic = value
        Task {
            await notifications.setCategory(category, enabled: value)
            if category == .trialReminder { await model.updateTrialReminder() }
            optimistic = nil // the stored value (e.g. off if iOS refused) takes over
            busy = false
        }
    }
}
