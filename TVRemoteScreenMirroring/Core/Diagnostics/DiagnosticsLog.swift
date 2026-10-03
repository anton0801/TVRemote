import Foundation
import os

/// Privacy-safe diagnostic trail used for support reports.
///
/// Only enumerated event codes and a few enumerated attributes are stored — there is no API
/// to log free text, so IP addresses, TV names, typed text, tokens or file names cannot end
/// up here by accident. Kept in memory plus a small protected file; nothing is uploaded unless
/// the user explicitly attaches it to a support message.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    enum Event: String, Codable, Sendable {
        case appLaunched, appForegrounded, appBackgrounded
        case discoveryStarted, discoveryFinished, discoveryPermissionDenied, discoveryNoWiFi
        case pairingStarted, pairingPromptShown, pairingSucceeded, pairingFailed
        case connectStarted, connected, disconnected, reconnectAttempt, reconnectGaveUp
        case commandFailed, commandUnsupported
        case textSent, textFailed, textFieldNotFocused
        case appLaunchSent, appLaunchConfirmed, appLaunchFailed
        case mediaPrepareStarted, mediaPrepareFailed, mediaCastStarted, mediaCastFailed, mediaCastStopped
        case mirroringSetupStarted, mirroringReceiverOpened, mirroringFirstFrame, mirroringStopped, mirroringFailed
        case paywallShown, purchaseStarted, purchaseSucceeded, purchasePending, purchaseCancelled, purchaseFailed
        case restoreStarted, restoreFinished, entitlementRefreshed, entitlementRefreshFailed
        case offerRedemptionStarted, offerVerified, offerFailed
        case supportOpened, keychainWriteFailed, storageWriteFailed, storageReadFailed
        case notificationPermissionResult, remoteNotificationRegistered
    }

    struct Entry: Codable, Sendable, Identifiable {
        var id: UUID = UUID()
        let date: Date
        let event: Event
        let platform: TVPlatform?
        let errorCode: String?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 200
    private let logger = Logger(subsystem: "app.TVRemoteScreenMirroring", category: "diagnostics")
    private let fileURL: URL?

    init(fileURL: URL? = DiagnosticsLog.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(stored.suffix(capacity))
        }
    }

    func record(_ event: Event, platform: TVPlatform? = nil, error: AppError? = nil) {
        let entry = Entry(date: .now, event: event, platform: platform, errorCode: error?.code)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        let snapshot = entries
        lock.unlock()
        logger.debug("\(event.rawValue, privacy: .public) \(platform?.rawValue ?? "-", privacy: .public) \(error?.code ?? "-", privacy: .public)")
        persist(snapshot)
    }

    func recentEntries(limit: Int = 40) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        writeGeneration += 1
        lock.unlock()
        guard let fileURL else { return }
        writeQueue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Serial writes in order; a snapshot taken before `clear()` is never written after it.
    private let writeQueue = DispatchQueue(label: "diagnostics.write", qos: .utility)
    private var writeGeneration = 0

    private func persist(_ snapshot: [Entry]) {
        guard let fileURL else { return }
        let generation = lock.withLock { writeGeneration }
        writeQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.writeGeneration }) == generation else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.json")
    }
}
