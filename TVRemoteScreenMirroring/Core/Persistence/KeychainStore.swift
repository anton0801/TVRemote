import Foundation
import Security

/// Minimal generic-password Keychain wrapper for pairing credentials.
/// Items are device-only (`ThisDeviceOnly`) and available after first unlock so a reconnect
/// can happen while the phone is locked during mirroring.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "app.TVRemoteScreenMirroring.credentials") {
        self.service = service
    }

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    func set(_ data: Data, for account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery(account)
            addQuery.merge(attributes) { $1 }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every item of this service (UI-test reset only).
    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    func codable<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        guard let data = try? data(for: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setCodable<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Everything needed to reconnect to a paired TV without a new prompt.
struct TVCredentials: Codable, Hashable, Sendable {
    /// Samsung token or LG client-key.
    var token: String?
    /// SHA-256 of the TV's TLS leaf certificate, pinned on first successful pairing (TOFU).
    var pinnedCertificateSHA256: String?
    /// Keychain label of the client TLS identity (Android TV).
    var clientIdentityLabel: String?
    /// Last known working port / transport hint (e.g. LG 3001 vs 3000).
    var portHint: UInt16?
}

/// Stores credentials per device ID. Removing a TV removes its credentials.
struct CredentialStore: Sendable {
    private let keychain = KeychainStore()

    func credentials(for id: TVDeviceID) -> TVCredentials? {
        keychain.codable(TVCredentials.self, for: id.rawValue)
    }

    func save(_ credentials: TVCredentials, for id: TVDeviceID) {
        do {
            try keychain.setCodable(credentials, for: id.rawValue)
        } catch {
            DiagnosticsLog.shared.record(.keychainWriteFailed)
        }
    }

    func remove(for id: TVDeviceID) {
        if let label = credentials(for: id)?.clientIdentityLabel {
            ClientIdentityStore.removeIdentity(label: label)
        }
        keychain.remove(id.rawValue)
    }
}
