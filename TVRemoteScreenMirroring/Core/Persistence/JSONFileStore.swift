import Foundation

/// Small atomic JSON file persistence in Application Support with data protection.
struct JSONFileStore<Value: Codable>: Sendable {
    let fileName: String
    let directory: URL
    /// Private, short-lived data (support drafts) stays out of iCloud / computer backups.
    let excludedFromBackup: Bool

    init(fileName: String, directory: URL? = nil, excludedFromBackup: Bool = false) {
        self.fileName = fileName
        self.directory = directory ?? Self.applicationSupport
        self.excludedFromBackup = excludedFromBackup
    }

    static var applicationSupport: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var url: URL { directory.appendingPathComponent(fileName) }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            // Unreadable (corrupt, or written by an incompatible version): keep a copy instead of
            // letting the next save silently overwrite it, and record it for support.
            let backup = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            DiagnosticsLog.shared.record(.storageReadFailed)
            return nil
        }
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if excludedFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var fileURL = url
                try? fileURL.setResourceValues(values)
            }
        } catch {
            DiagnosticsLog.shared.record(.storageWriteFailed)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
