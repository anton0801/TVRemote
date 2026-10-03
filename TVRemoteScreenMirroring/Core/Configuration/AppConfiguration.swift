import Foundation

/// Owner-controlled release configuration, loaded from `AppConfig.plist`.
/// Empty values mean "not configured": the dependent feature shows an honest unavailable
/// state instead of pointing at an invented service.
struct AppConfiguration: Sendable {
    struct Products: Sendable {
        var monthly: String
        var yearly: String
        var lifetime: String
        var subscriptionGroupID: String?

        var subscriptionIDs: [String] { [monthly, yearly] }
        var all: [String] { [monthly, yearly, lifetime] }
    }

    struct DiagnosticLimits: Sendable {
        /// Seconds of successful remote connection per TV before Remote Pro is needed.
        var remoteSeconds: Int
        /// Test photo shows per TV.
        var photoShows: Int
        /// Seconds of own screen mirroring after the TV confirmed the first frame.
        var mirroringSeconds: Int
    }

    struct BonusCampaign: Sendable {
        var enabled: Bool
        var campaignID: String
        var rulesVersion: String
        /// HTTPS endpoint of the offer-code reservation service. Empty = campaign cannot run.
        var codeServiceURL: URL?
        var qualifyingVisitNumber: Int
        var minimumSessionSeconds: Int
        var minimumMinutesBetweenVisits: Int
        var rulesURL: URL?
        var organizerName: String
    }

    struct Notifications: Sendable {
        /// HTTPS endpoint that stores FCM tokens and consent. Empty = remote categories unavailable.
        var registrationURL: URL?
    }

    var appStoreID: String
    var supportEmail: String
    var supportFormURL: URL?
    var supportPageURL: URL?
    var termsURL: URL
    var privacyURL: URL?
    var products: Products
    var limits: DiagnosticLimits
    var bonus: BonusCampaign
    var notifications: Notifications
    var supportReplyLanguages: [String]
    var supportDraftRetentionDays: Int

    var isSupportEmailConfigured: Bool { supportEmail.contains("@") }
    var isSupportFormConfigured: Bool { supportFormURL?.scheme == "https" }

    /// Apple's standard EULA is the documented default when the owner has no custom terms.
    static let appleStandardEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        guard let url = bundle.url(forResource: "AppConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return .fallback
        }
        return AppConfiguration(plist: plist)
    }

    init(plist: [String: Any]) {
        func string(_ key: String, in dict: [String: Any]) -> String {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func url(_ key: String, in dict: [String: Any]) -> URL? {
            let value = string(key, in: dict)
            guard !value.isEmpty, let url = URL(string: value), url.scheme == "https" else { return nil }
            return url
        }
        func int(_ key: String, in dict: [String: Any], default value: Int) -> Int {
            (dict[key] as? Int) ?? value
        }

        appStoreID = string("AppStoreID", in: plist)
        supportEmail = string("SupportEmail", in: plist)
        supportFormURL = url("SupportFormURL", in: plist)
        supportPageURL = url("SupportPageURL", in: plist)
        termsURL = url("TermsOfUseURL", in: plist) ?? Self.appleStandardEULA
        privacyURL = url("PrivacyPolicyURL", in: plist)
        supportReplyLanguages = (plist["SupportReplyLanguages"] as? [String]) ?? ["en"]
        supportDraftRetentionDays = int("SupportDraftRetentionDays", in: plist, default: 7)

        let productDict = plist["Products"] as? [String: Any] ?? [:]
        products = Products(
            monthly: string("Monthly", in: productDict).nonEmpty ?? "remote_pro_monthly",
            yearly: string("Yearly", in: productDict).nonEmpty ?? "remote_pro_yearly",
            lifetime: string("Lifetime", in: productDict).nonEmpty ?? "remote_pro_lifetime",
            subscriptionGroupID: string("SubscriptionGroupID", in: productDict).nonEmpty
        )

        let limitDict = plist["DiagnosticLimits"] as? [String: Any] ?? [:]
        limits = DiagnosticLimits(
            remoteSeconds: int("RemoteSeconds", in: limitDict, default: 120),
            photoShows: int("PhotoShows", in: limitDict, default: 1),
            mirroringSeconds: int("MirroringSeconds", in: limitDict, default: 60)
        )

        let bonusDict = plist["BonusCampaign"] as? [String: Any] ?? [:]
        bonus = BonusCampaign(
            enabled: (bonusDict["Enabled"] as? Bool) ?? false,
            campaignID: string("CampaignID", in: bonusDict).nonEmpty ?? "welcome-wheel-v1",
            rulesVersion: string("RulesVersion", in: bonusDict).nonEmpty ?? "1",
            codeServiceURL: url("CodeServiceURL", in: bonusDict),
            qualifyingVisitNumber: int("QualifyingVisitNumber", in: bonusDict, default: 3),
            minimumSessionSeconds: int("MinimumSessionSeconds", in: bonusDict, default: 20),
            minimumMinutesBetweenVisits: int("MinimumMinutesBetweenVisits", in: bonusDict, default: 30),
            rulesURL: url("RulesURL", in: bonusDict),
            organizerName: string("OrganizerName", in: bonusDict)
        )

        let notificationDict = plist["Notifications"] as? [String: Any] ?? [:]
        notifications = Notifications(registrationURL: url("RegistrationURL", in: notificationDict))
    }

    static let fallback = AppConfiguration(plist: [:])
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
