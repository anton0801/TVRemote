import Foundation

/// Product analytics schema (spec §21, §35.2). Parameters are enumerated or numeric only:
/// there is no case that can carry typed text, TV names, addresses, media or codes.
enum AnalyticsEvent: Equatable, Sendable {
    enum Feature: String, Sendable { case remote, keyboard, apps, photo, video, mirroring }
    enum PaywallContext: String, Sendable { case remote, mirroring, settings, bonus }
    enum Plan: String, Sendable { case monthly, yearly, lifetime }
    enum Result: String, Sendable { case success, failure, cancelled, pending, unconfirmed }
    enum SupportChannel: String, Sendable { case email, webForm, copy }

    case onboardingStarted
    case onboardingCompleted(task: String)
    case discoveryStarted
    case discoveryCompleted(found: Int, permissionDenied: Bool)
    case localNetworkPermissionResult(granted: Bool)
    case pairingStarted(platform: TVPlatform)
    case pairingSucceeded(platform: TVPlatform)
    case pairingFailed(platform: TVPlatform, errorCode: String)
    case capabilityCheckCompleted(platform: TVPlatform, usableCount: Int)
    case remoteSessionStarted(platform: TVPlatform)
    case remoteSessionEnded(platform: TVPlatform, commandCount: Int, durationSeconds: Int)
    case textSendResult(platform: TVPlatform, result: Result, errorCode: String?)
    case tvAppLaunchResult(platform: TVPlatform, appID: String, result: Result)
    case mediaCastStarted(platform: TVPlatform, isVideo: Bool)
    case mediaCastFailed(platform: TVPlatform, errorCode: String)
    case mirroringStarted(platform: TVPlatform)
    case mirroringStopped(platform: TVPlatform, durationSeconds: Int)
    case mirroringFailed(platform: TVPlatform, errorCode: String)
    case diagnosticCompleted(feature: Feature, exhausted: Bool)
    case paywallViewed(context: PaywallContext)
    case planSelected(plan: Plan)
    case purchaseStarted(plan: Plan)
    case purchasePending(plan: Plan)
    case purchaseFailed(plan: Plan, errorCode: String)
    case purchaseCancelled(plan: Plan)
    case purchaseCompleted(plan: Plan)
    case trialStarted(plan: Plan)
    case restoreCompleted(found: Bool)
    case subscriptionManagementOpened
    case supportOpened(source: String)
    case supportChannelSelected(channel: SupportChannel)
    case diagnosticPreviewed
    case changePlanOpened
    case planChangeRequested(plan: Plan)
    case planChangeConfirmed(plan: Plan)
    case bonusInvitationShown
    case bonusDismissed
    case bonusAssigned(sector: String)
    case offerRedemptionStarted(plan: Plan)
    case offerVerified(plan: Plan)
    case offerFailed(plan: Plan, errorCode: String)
    case notificationPermissionResult(granted: Bool)

    /// Allowed catalog app IDs for `tvAppLaunchResult` (never arbitrary installed-app names).
    static func sanitizedAppID(_ id: String) -> String {
        TVAppCatalog.entry(id: id) != nil ? id : "other"
    }

    var name: String {
        switch self {
        case .onboardingStarted: "onboarding_started"
        case .onboardingCompleted: "onboarding_completed"
        case .discoveryStarted: "discovery_started"
        case .discoveryCompleted: "discovery_completed"
        case .localNetworkPermissionResult: "local_network_permission_result"
        case .pairingStarted: "pairing_started"
        case .pairingSucceeded: "pairing_succeeded"
        case .pairingFailed: "pairing_failed"
        case .capabilityCheckCompleted: "capability_check_completed"
        case .remoteSessionStarted: "remote_session_started"
        case .remoteSessionEnded: "remote_session_ended"
        case .textSendResult: "text_send_result"
        case .tvAppLaunchResult: "tv_app_launch_result"
        case .mediaCastStarted: "media_cast_started"
        case .mediaCastFailed: "media_cast_failed"
        case .mirroringStarted: "mirroring_started"
        case .mirroringStopped: "mirroring_stopped"
        case .mirroringFailed: "mirroring_failed"
        case .diagnosticCompleted: "diagnostic_completed"
        case .paywallViewed: "paywall_viewed"
        case .planSelected: "plan_selected"
        case .purchaseStarted: "purchase_started"
        case .purchasePending: "purchase_pending"
        case .purchaseFailed: "purchase_failed"
        case .purchaseCancelled: "purchase_cancelled"
        case .purchaseCompleted: "purchase_completed"
        case .trialStarted: "trial_started"
        case .restoreCompleted: "restore_completed"
        case .subscriptionManagementOpened: "subscription_management_opened"
        case .supportOpened: "support_opened"
        case .supportChannelSelected: "support_channel_selected"
        case .diagnosticPreviewed: "diagnostic_previewed"
        case .changePlanOpened: "change_plan_opened"
        case .planChangeRequested: "plan_change_requested"
        case .planChangeConfirmed: "plan_change_confirmed"
        case .bonusInvitationShown: "bonus_invitation_shown"
        case .bonusDismissed: "bonus_dismissed"
        case .bonusAssigned: "bonus_assigned"
        case .offerRedemptionStarted: "offer_redemption_started"
        case .offerVerified: "offer_verified"
        case .offerFailed: "offer_failed"
        case .notificationPermissionResult: "notification_permission_result"
        }
    }

    var parameters: [String: AnalyticsValue] {
        switch self {
        case .onboardingStarted, .discoveryStarted, .subscriptionManagementOpened, .diagnosticPreviewed,
             .changePlanOpened, .bonusInvitationShown, .bonusDismissed:
            return [:]
        case .onboardingCompleted(let task):
            return ["task": .string(task == "mirroring" ? "mirroring" : "remote")]
        case .discoveryCompleted(let found, let denied):
            return ["found_count": .int(min(found, 20)), "permission_denied": .bool(denied)]
        case .localNetworkPermissionResult(let granted), .notificationPermissionResult(let granted):
            return ["granted": .bool(granted)]
        case .pairingStarted(let platform), .pairingSucceeded(let platform), .remoteSessionStarted(let platform), .mirroringStarted(let platform):
            return ["tv_platform": .string(platform.analyticsValue)]
        case .pairingFailed(let platform, let code), .mediaCastFailed(let platform, let code), .mirroringFailed(let platform, let code):
            return ["tv_platform": .string(platform.analyticsValue), "error_code": .string(code)]
        case .capabilityCheckCompleted(let platform, let count):
            return ["tv_platform": .string(platform.analyticsValue), "usable_count": .int(count)]
        case .remoteSessionEnded(let platform, let commands, let duration):
            return ["tv_platform": .string(platform.analyticsValue), "command_count": .int(commands), "duration_s": .int(duration)]
        case .textSendResult(let platform, let result, let code):
            var params: [String: AnalyticsValue] = ["tv_platform": .string(platform.analyticsValue), "result": .string(result.rawValue)]
            if let code { params["error_code"] = .string(code) }
            return params
        case .tvAppLaunchResult(let platform, let appID, let result):
            return ["tv_platform": .string(platform.analyticsValue), "app": .string(Self.sanitizedAppID(appID)), "result": .string(result.rawValue)]
        case .mediaCastStarted(let platform, let isVideo):
            return ["tv_platform": .string(platform.analyticsValue), "media": .string(isVideo ? "video" : "photo")]
        case .mirroringStopped(let platform, let duration):
            return ["tv_platform": .string(platform.analyticsValue), "duration_s": .int(duration)]
        case .diagnosticCompleted(let feature, let exhausted):
            return ["feature": .string(feature.rawValue), "exhausted": .bool(exhausted)]
        case .paywallViewed(let context):
            return ["paywall_context": .string(context.rawValue)]
        case .planSelected(let plan), .purchaseStarted(let plan), .purchasePending(let plan), .purchaseCancelled(let plan),
             .purchaseCompleted(let plan), .trialStarted(let plan), .planChangeRequested(let plan), .planChangeConfirmed(let plan),
             .offerRedemptionStarted(let plan), .offerVerified(let plan):
            return ["plan": .string(plan.rawValue)]
        case .purchaseFailed(let plan, let code), .offerFailed(let plan, let code):
            return ["plan": .string(plan.rawValue), "error_code": .string(code)]
        case .restoreCompleted(let found):
            return ["found": .bool(found)]
        case .supportOpened(let source):
            return ["source": .string(source)]
        case .supportChannelSelected(let channel):
            return ["channel": .string(channel.rawValue)]
        case .bonusAssigned(let sector):
            return ["sector": .string(sector)]
        }
    }
}

enum AnalyticsValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value ? 1 : 0
        }
    }
}
