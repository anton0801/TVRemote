import SwiftUI

// MARK: - Grouped rows

/// Uppercase group header and rows on one rounded surface (design 22). Place
/// `SettingsDivider()` between rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title {
                Text(title.uppercased(with: L10n.locale))
                    .font(.appSectionLabel)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, Spacing.xxs)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, Spacing.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Inset divider placed between rows of a `SettingsGroup`.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color.appBorder.opacity(0.8)).frame(height: 0.5).padding(.leading, 60)
    }
}

/// Row icon: plain kit icon (navigation rows) or the same icon on a small tile (toggles).
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .appTextPrimary
    var tiled = false

    var body: some View {
        if tiled {
            IconTile(name: symbol, tint: .appAccent, size: 36)
        } else {
            AppIconView(symbol, size: 26)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
        }
    }
}

/// Row layout: icon, title with optional subtitle, optional value, trailing accessory.
struct SettingsRowLabel: View {
    enum Accessory { case chevron, menu, none, external }

    let symbol: String
    let title: String
    var subtitle: String?
    var value: String?
    var accessory: Accessory = .chevron
    var tint: Color = .appTextPrimary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.s) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let value, dynamicTypeSize.isAccessibilitySize {
                    Text(value).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                }
            }
            .layoutPriority(1) // the value wraps first, never the row title
            Spacer(minLength: Spacing.xs)
            if let value, !dynamicTypeSize.isAccessibilitySize {
                Text(value)
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.trailing)
            }
            switch accessory {
            case .chevron:
                AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary)
            case .menu:
                Image(systemName: "chevron.up.chevron.down").font(.appSectionLabel).foregroundStyle(Color.appTextSecondary)
            case .external:
                AppIconView("icon-external-link", size: 16).foregroundStyle(Color.appTextSecondary)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: HitTarget.row)
        .contentShape(Rectangle())
    }
}

/// Picker presented as a menu with the current value on the right.
struct SettingsMenuRow<Value: Hashable>: View {
    let symbol: String
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
        } label: {
            SettingsRowLabel(symbol: symbol, title: title, value: options.first { $0.0 == selection }?.1, accessory: .menu)
        }
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

struct SettingsToggleRow: View {
    let symbol: String
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var isEnabled = true
    /// Icon on a tile (notification and privacy toggles) or plain (Haptic feedback).
    var tiled = true

    var body: some View {
        // The whole row is the switch's label, so VoiceOver reads title + detail + state once.
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.s) {
                SettingsIcon(symbol: symbol, tiled: tiled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appBody).foregroundStyle(Color.appTextPrimary)
                    if let detail {
                        Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Color.appAccentFill)
        .disabled(!isEnabled)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: HitTarget.row)
    }
}

// MARK: - Remote Pro banner

/// Top-of-settings banner. Never offers a purchase while an existing purchase is being verified.
struct RemoteProBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Copy {
        var title: String
        var message: String
        var action: String?
        var isPrimaryAction: Bool
    }

    private var copy: Copy {
        func date(_ value: Date?) -> String {
            value.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale)) } ?? "—"
        }
        switch model.entitlements.state {
        case .verifying:
            return Copy(title: L10n.tr("banner.pro.title"), message: L10n.tr("access.verifying"), action: nil, isPrimaryAction: false)
        case .inactive(.billingRetry):
            return Copy(title: L10n.tr("banner.pro.title"), message: L10n.tr("banner.pro.billingIssue"), action: L10n.tr("banner.pro.manageSubscription"), isPrimaryAction: false)
        case .inactive:
            return Copy(title: L10n.tr("banner.pro.title"), message: L10n.tr("v2.pro.banner"), action: L10n.tr("v2.pro.explore"), isPrimaryAction: true)
        case .active(let access):
            if access.isLifetime {
                let message = access.coexistingSubscription?.willAutoRenew == true
                    ? L10n.tr("banner.pro.lifetime.oldSubscription") : L10n.tr("banner.pro.lifetime.message")
                return Copy(title: L10n.tr("banner.pro.lifetime.title"), message: message,
                            action: access.coexistingSubscription?.willAutoRenew == true ? L10n.tr("pro.manageExisting") : L10n.tr("banner.pro.details"),
                            isPrimaryAction: false)
            }
            if access.phase == .introductoryTrial || access.phase == .offerFreePeriod {
                return Copy(title: L10n.tr("banner.pro.trial.title"), message: L10n.tr("pro.trial.until", date(access.expirationDate)),
                            action: L10n.tr("banner.pro.manageAccess"), isPrimaryAction: false)
            }
            let planTitle = L10n.tr("banner.pro.plan.\(access.plan.rawValue)")
            let message: String
            if access.inGracePeriod {
                message = L10n.tr("banner.pro.billingIssue")
            } else if access.willAutoRenew == false {
                message = L10n.tr("pro.autoRenewOff", date(access.expirationDate))
            } else {
                message = L10n.tr("banner.pro.renews", date(access.renewalDate ?? access.expirationDate))
            }
            return Copy(title: planTitle, message: message, action: L10n.tr("banner.pro.manageSubscription"), isPrimaryAction: false)
        }
    }

    var body: some View {
        let copy = copy
        HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    AppIconView("icon-spark", size: 24).foregroundStyle(Color.appAccent)
                    Text(copy.title)
                        .font(.appBannerTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: Spacing.xs) {
                    if model.entitlements.state == .verifying { ProgressView().controlSize(.small) }
                    Text(copy.message)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = copy.action {
                    Button { perform() } label: {
                        HStack(spacing: Spacing.xxs) {
                            Text(action)
                            AppIconView("icon-chevron-right", size: 14, relativeTo: .subheadline)
                        }
                    }
                    .font(.appSecondary.weight(.semibold))
                    .foregroundStyle(copy.isPrimaryAction ? Color.appOnAccent : Color.appAccent)
                    .padding(.horizontal, copy.isPrimaryAction ? Spacing.m : 0)
                    .frame(minHeight: 40)
                    .background {
                        if copy.isPrimaryAction { Capsule().fill(Color.appAccentFill) }
                    }
                    .padding(.top, Spacing.xxs)
                    .accessibilityIdentifier("settings.remotePro")
                }
            }
            Spacer(minLength: 0)
            if !dynamicTypeSize.isAccessibilitySize {
                BannerGlyph()
                    .frame(width: 112, height: 82)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(LinearGradient(colors: [Color.appAccentTint, Color.appSurface], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(Color.appAccentFill.opacity(0.75), lineWidth: 1.2)
        )
        .accessibilityElement(children: .contain)
    }

    private func perform() {
        switch model.entitlements.state {
        case .inactive(.billingRetry), .active:
            model.sheet = .remotePro
        case .inactive:
            model.paywall.present(.remote, feature: nil, deviceID: model.devices.selectedDeviceID)
        case .verifying:
            break
        }
    }
}

/// Small TV illustration for the banner.
private struct BannerGlyph: View {
    var body: some View {
        Image(ArtAsset.proBanner.rawValue)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}
