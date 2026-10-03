import Foundation

/// Local, fully translated help articles (spec §31.1). Text lives in the string catalog:
/// `help.<id>.title`, `help.<id>.intro`, `help.<id>.step<n>`.
struct HelpArticle: Identifiable, Hashable, Sendable {
    typealias ID = String

    enum Action: Hashable, Sendable {
        case openAppSettings
        case searchAgain
        case restorePurchases
        case manageSubscription
        case openRemotePro
        case openPrivacySettings
    }

    let id: ID
    let symbol: String
    let stepCount: Int
    let action: Action?
    let supportCategory: SupportCategory

    var titleKey: String { "help.\(id).title" }
    var introKey: String { "help.\(id).intro" }
    var stepKeys: [String] { (1...stepCount).map { "help.\(id).step\($0)" } }

    static let all: [HelpArticle] = [
        HelpArticle(id: "tvNotFound", symbol: "icon-wifi-off", stepCount: 5, action: .searchAgain, supportCategory: .tvNotFound),
        HelpArticle(id: "cannotConnect", symbol: "icon-wifi", stepCount: 4, action: nil, supportCategory: .cannotConnect),
        HelpArticle(id: "buttonsNotWorking", symbol: "icon-buttons", stepCount: 4, action: nil, supportCategory: .buttonsNotWorking),
        HelpArticle(id: "textNotWorking", symbol: "icon-keyboard", stepCount: 4, action: nil, supportCategory: .textNotWorking),
        HelpArticle(id: "appsNotLaunching", symbol: "icon-apps", stepCount: 4, action: nil, supportCategory: .appsNotLaunching),
        HelpArticle(id: "mediaNotShowing", symbol: "icon-photo", stepCount: 4, action: nil, supportCategory: .mediaNotShowing),
        HelpArticle(id: "mirroringProblem", symbol: "icon-mirror", stepCount: 4, action: nil, supportCategory: .mirroringProblem),
        HelpArticle(id: "paidNoAccess", symbol: "icon-restore", stepCount: 4, action: .restorePurchases, supportCategory: .paidNoAccess),
        HelpArticle(id: "trialOffers", symbol: "icon-calendar", stepCount: 4, action: .openRemotePro, supportCategory: .trialOffers),
        HelpArticle(id: "changePlan", symbol: "icon-refresh", stepCount: 4, action: .manageSubscription, supportCategory: .changePlan),
        HelpArticle(id: "refund", symbol: "arrow.uturn.backward.circle", stepCount: 3, action: nil, supportCategory: .refund),
        HelpArticle(id: "privacy", symbol: "icon-shield", stepCount: 4, action: .openPrivacySettings, supportCategory: .privacy),
    ]

    static func article(_ id: ID) -> HelpArticle? { all.first { $0.id == id } }

    /// Best article for an error shown to the user.
    static func article(for error: AppError) -> HelpArticle? {
        let id: ID
        switch error {
        case .localNetworkDenied, .noWiFi, .discoveryFoundNothing, .deviceUnreachable, .deviceAddressChanged: id = "tvNotFound"
        case .pairingRejected, .pairingTimedOut, .pairingWrongPIN, .pairingTokenRevoked, .pairingUnsupportedFirmware, .tlsIdentityMismatch, .connectionLost: id = "cannotConnect"
        case .commandNotSupported, .commandTimedOut: id = "buttonsNotWorking"
        case .textFieldNotFocused, .textNotSupported, .textResultUnknown: id = "textNotWorking"
        case .appNotInstalled, .appLaunchFailed, .appListUnavailable: id = "appsNotLaunching"
        case .mediaRendererMissing, .mediaFormatUnsupported, .mediaLoadFailed, .mediaICloudDownloadFailed, .mediaInsufficientStorage, .mediaPlaybackFailed: id = "mediaNotShowing"
        case .mirroringReceiverMissing, .mirroringBrowserLaunchFailed, .mirroringStoppedBySystem, .mirroringNetworkLost, .mirroringProtectedContent, .mirroringThermal, .mirroringNotStarted: id = "mirroringProblem"
        case .storeProductsUnavailable, .purchasePending, .purchaseFailed, .purchaseNotAllowed, .restoreFoundNothing, .entitlementRefreshFailed: id = "paidNoAccess"
        case .offerUnavailable, .offerExpired, .offerAlreadyUsed, .offerSoldOut, .offerServiceUnavailable: id = "trialOffers"
        case .mailUnavailable, .supportNotConfigured, .unexpected: return nil
        }
        return article(id)
    }
}
