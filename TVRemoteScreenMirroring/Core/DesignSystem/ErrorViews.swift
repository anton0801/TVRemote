import SwiftUI
import UIKit

extension AppError {
    var localizedTitle: String { L10n.tr("\(localizationKey).title") }
    var localizedMessage: String { L10n.tr("\(localizationKey).message") }

    var localizedActionTitle: String? {
        switch recoveryAction {
        case .none: nil
        default: L10n.tr("action.\(recoveryAction.rawValue)")
        }
    }
}

extension TVPlatform {
    /// Platforms the app can control, in display order.
    static let supported: [TVPlatform] = [.samsungTizen, .lgWebOS, .androidTV]

    /// Platform names are product names and are not translated.
    var displayName: String {
        switch self {
        case .samsungTizen: "Samsung Tizen"
        case .lgWebOS: "LG webOS"
        case .androidTV: "Android TV / Google TV"
        case .unknown: L10n.tr("platform.unknown")
        }
    }

    var symbol: String {
        switch self {
        default: "tv"
        }
    }
}

enum SystemLinks {
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Error card with one recommended action and a way to get help.
struct ErrorCard: View {
    @Environment(AppModel.self) private var model
    let error: AppError
    var feature: String
    var onAction: ((AppError.RecoveryAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label {
                Text(error.localizedTitle)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
            } icon: {
                Image(systemName: error.category == .permission ? "lock.shield" : "exclamationmark.triangle")
                    .foregroundStyle(Color.appWarning)
            }
            Text(error.localizedMessage)
                .font(.appSecondary)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.m) {
                if let title = error.localizedActionTitle {
                    Button(title) {
                        if error.recoveryAction == .openSettings {
                            model.bonus.expectReturn()
                            SystemLinks.openAppSettings()
                        } else if error.recoveryAction == .contactSupport {
                            model.openSupport(errorCode: error.code, feature: feature)
                        } else {
                            onAction?(error.recoveryAction)
                        }
                    }
                    .font(.appSecondary.weight(.semibold))
                    .frame(minHeight: HitTarget.minimum)
                }
                Spacer(minLength: 0)
                Button(L10n.tr("common.getHelp")) {
                    model.present(.help(HelpArticle.article(for: error)?.id))
                }
                .font(.appSecondary)
                .frame(minHeight: HitTarget.minimum)
            }
            Text(L10n.tr("common.errorCode", error.code))
                .font(.appCaption)
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityLabel(L10n.tr("common.errorCode.accessibility", error.code))
        }
        .surfaceCard()
    }
}
