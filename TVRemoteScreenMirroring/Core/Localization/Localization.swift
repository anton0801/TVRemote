import Foundation
import Observation

/// Languages offered in Settings. `system` follows the iOS language order.
enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, en, es, ru, de, fr

    var id: String { rawValue }

    /// Name of the language written in that language (not translated on purpose).
    var endonym: String {
        switch self {
        case .system: ""
        case .en: "English"
        case .es: "Español"
        case .ru: "Русский"
        case .de: "Deutsch"
        case .fr: "Français"
        }
    }

    static let supportedCodes = ["en", "es", "ru", "de", "fr"]
}

/// In-app language override without swizzling `Bundle.main`: strings are looked up explicitly
/// in the chosen `.lproj` bundle, and formatting uses the matching `Locale`.
/// System-owned UI (permission prompts, App Store sheets, purchase dialogs) keeps following
/// the iOS language — documented in README.
@MainActor
@Observable
final class LocalizationManager {
    private(set) var language: AppLanguage
    private(set) var locale: Locale
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = AppLanguage(rawValue: defaults.string(forKey: "settings.language") ?? "") ?? .system
        language = stored
        locale = Self.resolvedLocale(for: stored)
        L10n.configure(languageCode: Self.resolvedCode(for: stored), locale: locale)
    }

    /// Effective language code used for lookups.
    var effectiveCode: String { Self.resolvedCode(for: language) }

    func setLanguage(_ newValue: AppLanguage) {
        language = newValue
        defaults.set(newValue.rawValue, forKey: "settings.language")
        locale = Self.resolvedLocale(for: newValue)
        L10n.configure(languageCode: Self.resolvedCode(for: newValue), locale: locale)
    }

    nonisolated static func resolvedCode(for language: AppLanguage, preferred: [String] = Bundle.main.preferredLocalizations) -> String {
        if language != .system { return language.rawValue }
        for code in preferred {
            let base = String(code.prefix(2))
            if AppLanguage.supportedCodes.contains(base) { return base }
        }
        return "en"
    }

    private static func resolvedLocale(for language: AppLanguage) -> Locale {
        guard language != .system else { return .autoupdatingCurrent }
        // Keep the user's region (number/date conventions) but switch the language.
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents = Locale.Language.Components(identifier: language.rawValue)
        return Locale(components: components)
    }
}

/// Global string lookup. Thread-safe; configured by `LocalizationManager`.
enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundle: Bundle = .main
    nonisolated(unsafe) private static var fallbackBundle: Bundle = .main
    nonisolated(unsafe) private static var currentLocale: Locale = .autoupdatingCurrent
    nonisolated(unsafe) private static var currentCode: String = "en"

    static func configure(languageCode: String, locale: Locale, in container: Bundle = .main) {
        let resolved = container.path(forResource: languageCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? container
        let english = container.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? container
        lock.lock()
        bundle = resolved
        fallbackBundle = english
        currentLocale = locale
        currentCode = languageCode
        lock.unlock()
    }

    static var locale: Locale {
        lock.lock(); defer { lock.unlock() }
        return currentLocale
    }

    static var languageCode: String {
        lock.lock(); defer { lock.unlock() }
        return currentCode
    }

    private static let missingMarker = "\u{1F}missing\u{1F}"

    /// Localized string for `key`. Falls back to English, never to the raw key in release.
    static func tr(_ key: String) -> String {
        lock.lock()
        let bundle = self.bundle
        let fallback = self.fallbackBundle
        lock.unlock()
        let value = bundle.localizedString(forKey: key, value: missingMarker, table: nil)
        if value != missingMarker { return value }
        let english = fallback.localizedString(forKey: key, value: missingMarker, table: nil)
        if english != missingMarker { return english }
        #if DEBUG
        return "⟦\(key)⟧"
        #else
        return ""
        #endif
    }

    /// Localized format string with arguments (`%@`, `%lld`, plural variations).
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        format(key, args)
    }

    static func format(_ key: String, _ args: [CVarArg]) -> String {
        let format = tr(key)
        return String(format: format, locale: locale, arguments: args)
    }
}
