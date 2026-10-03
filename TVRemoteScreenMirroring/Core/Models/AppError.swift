import Foundation

/// Stable, user-safe error catalog (spec §22, §32). `code` is what diagnostics and support
/// reports carry; messages are localized separately and never contain raw protocol output.
enum AppError: Error, Equatable, Sendable {
    // Network / discovery
    case localNetworkDenied
    case noWiFi
    case discoveryFoundNothing
    case deviceUnreachable
    case deviceAddressChanged
    // Pairing
    case pairingRejected
    case pairingTimedOut
    case pairingWrongPIN
    case pairingTokenRevoked
    case pairingUnsupportedFirmware
    case tlsIdentityMismatch
    // Session
    case connectionLost
    case commandNotSupported
    case commandTimedOut
    // Text
    case textFieldNotFocused
    case textNotSupported
    case textResultUnknown
    // Apps
    case appNotInstalled
    case appLaunchFailed
    case appListUnavailable
    // Media
    case mediaRendererMissing
    case mediaFormatUnsupported
    case mediaLoadFailed
    case mediaICloudDownloadFailed
    case mediaInsufficientStorage
    case mediaPlaybackFailed
    // Mirroring
    case mirroringReceiverMissing
    case mirroringBrowserLaunchFailed
    case mirroringStoppedBySystem
    case mirroringNetworkLost
    case mirroringProtectedContent
    case mirroringThermal
    case mirroringNotStarted
    // Purchases
    case storeProductsUnavailable
    case purchasePending
    case purchaseFailed
    case purchaseNotAllowed
    case restoreFoundNothing
    case entitlementRefreshFailed
    // Offers
    case offerUnavailable
    case offerExpired
    case offerAlreadyUsed
    case offerSoldOut
    case offerServiceUnavailable
    // Support
    case mailUnavailable
    case supportNotConfigured
    // Generic
    case unexpected

    /// Stable diagnostic code. Never localized, never changes between releases.
    var code: String {
        switch self {
        case .localNetworkDenied: "NET-001"
        case .noWiFi: "NET-002"
        case .discoveryFoundNothing: "NET-003"
        case .deviceUnreachable: "NET-004"
        case .deviceAddressChanged: "NET-005"
        case .pairingRejected: "PAIR-001"
        case .pairingTimedOut: "PAIR-002"
        case .pairingWrongPIN: "PAIR-003"
        case .pairingTokenRevoked: "PAIR-004"
        case .pairingUnsupportedFirmware: "PAIR-005"
        case .tlsIdentityMismatch: "PAIR-006"
        case .connectionLost: "SES-001"
        case .commandNotSupported: "SES-002"
        case .commandTimedOut: "SES-003"
        case .textFieldNotFocused: "TXT-001"
        case .textNotSupported: "TXT-002"
        case .textResultUnknown: "TXT-003"
        case .appNotInstalled: "APP-001"
        case .appLaunchFailed: "APP-002"
        case .appListUnavailable: "APP-003"
        case .mediaRendererMissing: "MED-001"
        case .mediaFormatUnsupported: "MED-002"
        case .mediaLoadFailed: "MED-003"
        case .mediaICloudDownloadFailed: "MED-004"
        case .mediaInsufficientStorage: "MED-005"
        case .mediaPlaybackFailed: "MED-006"
        case .mirroringReceiverMissing: "MIR-001"
        case .mirroringBrowserLaunchFailed: "MIR-002"
        case .mirroringStoppedBySystem: "MIR-003"
        case .mirroringNetworkLost: "MIR-004"
        case .mirroringProtectedContent: "MIR-005"
        case .mirroringThermal: "MIR-006"
        case .mirroringNotStarted: "MIR-007"
        case .storeProductsUnavailable: "IAP-001"
        case .purchasePending: "IAP-002"
        case .purchaseFailed: "IAP-003"
        case .purchaseNotAllowed: "IAP-004"
        case .restoreFoundNothing: "IAP-005"
        case .entitlementRefreshFailed: "IAP-006"
        case .offerUnavailable: "OFR-001"
        case .offerExpired: "OFR-002"
        case .offerAlreadyUsed: "OFR-003"
        case .offerSoldOut: "OFR-004"
        case .offerServiceUnavailable: "OFR-005"
        case .mailUnavailable: "SUP-001"
        case .supportNotConfigured: "SUP-002"
        case .unexpected: "GEN-001"
        }
    }

    enum Category: String, Sendable {
        case temporary, permission, unsupported, purchase, externalService
    }

    var category: Category {
        switch self {
        case .localNetworkDenied: .permission
        case .commandNotSupported, .textNotSupported, .mediaRendererMissing, .mediaFormatUnsupported,
             .mirroringReceiverMissing, .mirroringProtectedContent, .pairingUnsupportedFirmware, .appNotInstalled:
            .unsupported
        case .storeProductsUnavailable, .purchasePending, .purchaseFailed, .purchaseNotAllowed,
             .restoreFoundNothing, .entitlementRefreshFailed:
            .purchase
        case .offerServiceUnavailable, .offerSoldOut, .mailUnavailable, .supportNotConfigured:
            .externalService
        default:
            .temporary
        }
    }

    /// The single recommended recovery action shown next to the message.
    enum RecoveryAction: String, Sendable {
        case retry, openSettings, pairAgain, searchAgain, useButtons, openHome, chooseAnotherFile,
             showSetupSteps, restorePurchases, managePayment, contactSupport, turnOnWithRemote, none
    }

    var recoveryAction: RecoveryAction {
        switch self {
        case .localNetworkDenied: .openSettings
        case .noWiFi, .discoveryFoundNothing: .searchAgain
        case .deviceUnreachable, .deviceAddressChanged, .connectionLost, .commandTimedOut: .retry
        case .pairingRejected, .pairingTimedOut, .pairingWrongPIN, .pairingTokenRevoked, .tlsIdentityMismatch: .pairAgain
        case .pairingUnsupportedFirmware: .contactSupport
        case .commandNotSupported, .textFieldNotFocused, .textNotSupported: .useButtons
        case .textResultUnknown: .retry
        case .appNotInstalled, .appLaunchFailed, .appListUnavailable: .openHome
        case .mediaRendererMissing: .contactSupport
        case .mediaFormatUnsupported, .mediaLoadFailed, .mediaICloudDownloadFailed, .mediaInsufficientStorage: .chooseAnotherFile
        case .mediaPlaybackFailed: .retry
        case .mirroringReceiverMissing, .mirroringBrowserLaunchFailed: .showSetupSteps
        case .mirroringStoppedBySystem, .mirroringNetworkLost, .mirroringThermal, .mirroringNotStarted: .retry
        case .mirroringProtectedContent: .none
        case .storeProductsUnavailable, .purchaseFailed, .entitlementRefreshFailed: .retry
        case .purchasePending, .purchaseNotAllowed: .none
        case .restoreFoundNothing: .contactSupport
        case .offerUnavailable, .offerExpired, .offerAlreadyUsed, .offerSoldOut, .offerServiceUnavailable: .none
        case .mailUnavailable, .supportNotConfigured: .none
        case .unexpected: .contactSupport
        }
    }

    /// Localization key prefix; `.title` and `.message` suffixes live in the string catalog.
    var localizationKey: String { "error.\(code.lowercased())" }

    static func wrap(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .unexpected }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return .commandTimedOut
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .connectionLost
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return .deviceUnreachable
            default: return .deviceUnreachable
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return .deviceUnreachable
        }
        return .unexpected
    }
}
