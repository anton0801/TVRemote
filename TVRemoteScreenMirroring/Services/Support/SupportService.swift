import Foundation
import Observation
import UIKit

enum SupportCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case tvNotFound, cannotConnect, buttonsNotWorking, textNotWorking, appsNotLaunching,
         mediaNotShowing, mirroringProblem, paidNoAccess, trialOffers, changePlan, refund, privacy, other

    var id: String { rawValue }
}

/// A support request the user prepares. Stored locally (complete file protection) until
/// sent or deleted, and purged after the retention period. Nothing is sent automatically.
struct SupportDraft: Codable, Equatable, Sendable {
    var category: SupportCategory = .other
    var problem = ""
    var expected = ""
    var tvModel = ""
    var contactEmail = ""
    var includeDiagnostics = false
    var createdAt = Date()
    var updatedAt = Date()
    var contextErrorCode: String?
    var contextFeature: String?

    var isEmpty: Bool { problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && expected.isEmpty }

    /// Loose shape check for the optional reply address (empty is valid — it's voluntary).
    static func isPlausibleEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !trimmed.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

/// Technical details the user can preview before attaching. Deliberately excludes IP/SSID/MAC,
/// TV names, serials, tokens, typed text, screen content, photos, receipts and transaction IDs.
struct SupportDiagnostics: Equatable, Sendable {
    var appVersion: String
    var build: String
    var iOSVersion: String
    var deviceModel: String
    var language: String
    var tvPlatform: String
    var errorCode: String
    var feature: String
    var timestamp: String
    var access: String
    var recentEvents: [String]

    func lines() -> [String] {
        [
            "App: \(appVersion) (\(build))",
            "iOS: \(iOSVersion)",
            "Device: \(deviceModel)",
            "Language: \(language)",
            "TV platform: \(tvPlatform)",
            "Feature: \(feature)",
            "Error code: \(errorCode)",
            "Time: \(timestamp)",
            "Access: \(access)",
            "Recent states:",
        ] + recentEvents.map { "  \($0)" }
    }
}

@MainActor
@Observable
final class SupportService {
    var draft = SupportDraft()
    /// Private text: excluded from iCloud / computer backups.
    private let store = JSONFileStore<SupportDraft>(fileName: "support-draft.json", excludedFromBackup: true)
    /// Last content written, to stamp `updatedAt` only when the text really changed (otherwise
    /// every trip to the background would postpone the automatic deletion forever).
    private var lastSavedContent: SupportDraft?
    private var saveTask: Task<Void, Never>?

    /// Limits keep typing smooth and mail links working.
    static let maxProblemLength = 5000
    static let maxExpectedLength = 2000
    let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        purgeExpiredDraft()
        if let saved = store.load() {
            draft = saved
            lastSavedContent = Self.content(of: saved)
        }
    }

    /// The draft without its timestamps (for "did anything change?").
    private static func content(of draft: SupportDraft) -> SupportDraft {
        var copy = draft
        copy.createdAt = .distantPast
        copy.updatedAt = .distantPast
        return copy
    }

    private var hasUserContent: Bool {
        !draft.isEmpty || !draft.tvModel.isEmpty || !draft.contactEmail.isEmpty
    }

    var hasEmailChannel: Bool { configuration.isSupportEmailConfigured }
    var hasFormChannel: Bool { configuration.isSupportFormConfigured }
    var isConfigured: Bool { hasEmailChannel || hasFormChannel }

    func start(category: SupportCategory?, errorCode: String?, feature: String?) {
        if let category { draft.category = category }
        // The context always describes *this* visit: an old error code must not leak into a
        // request opened later from Settings.
        draft.contextErrorCode = errorCode
        draft.contextFeature = feature
        saveDraft()
    }

    /// Persists the draft if its content changed. Only the stored copy is stamped: mutating
    /// `draft` here would re-trigger the view's `onChange(of: draft)` and loop. A draft with no
    /// text of the user's is not written at all.
    func saveDraft(now: Date = Date()) {
        saveTask?.cancel()
        saveTask = nil
        let content = Self.content(of: draft)
        guard content != lastSavedContent else { return }
        guard hasUserContent else {
            store.remove()
            lastSavedContent = content
            return
        }
        var stored = draft
        stored.updatedAt = now
        store.save(stored)
        lastSavedContent = content
    }

    /// Debounced save while typing (writing on every keystroke makes long texts lag).
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    func deleteDraft() {
        saveTask?.cancel()
        draft = SupportDraft()
        lastSavedContent = Self.content(of: draft)
        store.remove()
    }

    /// Removes a draft older than the retention period (default 7 days).
    func purgeExpiredDraft(now: Date = Date()) {
        guard let saved = store.load() else { return }
        let retention = TimeInterval(configuration.supportDraftRetentionDays) * 24 * 3600
        if now.timeIntervalSince(saved.updatedAt) > retention { store.remove() }
    }

    func diagnostics(platform: TVPlatform?, access: AccessState) -> SupportDiagnostics {
        let bundle = Bundle.main
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        let events = DiagnosticsLog.shared.recentEntries(limit: 25).map { entry in
            "\(formatter.string(from: entry.date)) \(entry.event.rawValue)\(entry.platform.map { " [\($0.rawValue)]" } ?? "")\(entry.errorCode.map { " \($0)" } ?? "")"
        }
        return SupportDiagnostics(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            iOSVersion: UIDevice.current.systemVersion,
            deviceModel: Self.hardwareModel(),
            language: L10n.languageCode,
            tvPlatform: platform?.rawValue ?? "none",
            errorCode: draft.contextErrorCode ?? "none",
            feature: draft.contextFeature ?? "none",
            timestamp: formatter.string(from: Date()) + " (\(TimeZone.current.identifier))",
            access: access.supportLabel,
            recentEvents: events
        )
    }

    /// Plain-text body used by every channel (mail, copy, form paste).
    func composedBody(diagnostics: SupportDiagnostics?) -> String {
        var parts: [String] = [
            "\(L10n.tr("support.field.category")): \(L10n.tr("support.category.\(draft.category.rawValue)"))",
            "",
            "\(L10n.tr("support.field.problem")):",
            draft.problem,
            "",
            "\(L10n.tr("support.field.expected")):",
            draft.expected,
            "",
            "\(L10n.tr("support.field.tvModel")): \(draft.tvModel.isEmpty ? L10n.tr("support.field.tvModel.unknown") : draft.tvModel)",
        ]
        let email = draft.contactEmail.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, SupportDraft.isPlausibleEmail(email) {
            parts += ["\(L10n.tr("support.field.contactEmail")): \(email)"]
        }
        if let diagnostics, draft.includeDiagnostics {
            parts += ["", "— \(L10n.tr("support.diagnostics.title")) —"] + diagnostics.lines()
        }
        return parts.joined(separator: "\n")
    }

    var subject: String {
        "TV Remote — \(L10n.tr("support.category.\(draft.category.rawValue)"))"
    }

    /// `mailto:` fallback (subject/body are part of the user's own message, not sent by us).
    /// Very long bodies are shortened: mail apps reject oversized links.
    func mailtoURL(body: String) -> URL? {
        guard hasEmailChannel else { return nil }
        let limit = 1800
        let text = body.count > limit ? String(body.prefix(limit)) + "\n…" : body
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = configuration.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: text)]
        return components.url
    }

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
