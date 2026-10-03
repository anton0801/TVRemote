import Foundation
import Observation
import SwiftUI

/// User preference for data collection. `undecided` behaves exactly like `denied`.
enum ConsentState: String, Codable, Sendable {
    case undecided, granted, denied

    var isGranted: Bool { self == .granted }
}

enum RemoteInputStyle: String, Codable, Sendable {
    case dpad, touchpad
}

/// Plain user preferences. Nothing here grants paid access.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboarding) } }
    var remoteInputStyle: RemoteInputStyle { didSet { defaults.set(remoteInputStyle.rawValue, forKey: Keys.inputStyle) } }
    var analyticsConsent: ConsentState { didSet { defaults.set(analyticsConsent.rawValue, forKey: Keys.analytics) } }
    var crashReportsConsent: ConsentState { didSet { defaults.set(crashReportsConsent.rawValue, forKey: Keys.crash) } }
    var trialReminderEnabled: Bool { didSet { defaults.set(trialReminderEnabled, forKey: Keys.trialReminder) } }
    var serviceNotificationsEnabled: Bool { didSet { defaults.set(serviceNotificationsEnabled, forKey: Keys.serviceNotifications) } }
    /// Separate explicit opt-in for promotional push (App Review 4.5.4). Off by default.
    var marketingNotificationsConsent: ConsentState { didSet { defaults.set(marketingNotificationsConsent.rawValue, forKey: Keys.marketing) } }
    var slideshowInterval: Int { didSet { defaults.set(slideshowInterval, forKey: Keys.slideshow) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The app has a single dark theme (design v2); an old light/system choice is dropped.
        defaults.removeObject(forKey: Keys.legacyTheme)
        hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        onboardingCompleted = defaults.bool(forKey: Keys.onboarding)
        remoteInputStyle = RemoteInputStyle(rawValue: defaults.string(forKey: Keys.inputStyle) ?? "") ?? .dpad
        analyticsConsent = ConsentState(rawValue: defaults.string(forKey: Keys.analytics) ?? "") ?? .undecided
        crashReportsConsent = ConsentState(rawValue: defaults.string(forKey: Keys.crash) ?? "") ?? .undecided
        trialReminderEnabled = defaults.bool(forKey: Keys.trialReminder)
        serviceNotificationsEnabled = defaults.bool(forKey: Keys.serviceNotifications)
        marketingNotificationsConsent = ConsentState(rawValue: defaults.string(forKey: Keys.marketing) ?? "") ?? .undecided
        let interval = defaults.integer(forKey: Keys.slideshow)
        slideshowInterval = [3, 5, 10].contains(interval) ? interval : 5
    }

    private enum Keys {
        static let legacyTheme = "settings.theme"
        static let haptics = "settings.haptics"
        static let onboarding = "settings.onboardingCompleted"
        static let inputStyle = "settings.remoteInputStyle"
        static let analytics = "settings.analyticsConsent"
        static let crash = "settings.crashConsent"
        static let trialReminder = "settings.trialReminder"
        static let serviceNotifications = "settings.serviceNotifications"
        static let marketing = "settings.marketingConsent"
        static let slideshow = "settings.slideshowInterval"
    }
}
