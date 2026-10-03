import Foundation
import Security

/// Creates and stores the TLS client identity used by the Android TV Remote v2 protocol.
///
/// The TV authenticates the phone by its client certificate. We generate an RSA-2048 key in
/// the Keychain (device-only) and a self-signed X.509 v3 certificate signed with that key,
/// built with a tiny DER encoder (no third-party crypto). One identity per paired TV, so
/// forgetting a TV removes exactly its certificate.
enum ClientIdentityStore {
    enum IdentityError: Error { case keyGeneration, signing, certificate, keychain(OSStatus), notFound }

    struct Identity {
        let identity: SecIdentity
        let certificate: SecCertificate
        let label: String
    }

    static func makeIdentity(commonName: String = "TV Remote iOS") throws -> Identity {
        let label = "atv.client.\(UUID().uuidString.lowercased())"
        let tag = Data(label.utf8)
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw IdentityError.keyGeneration }

        let certificateDER = try makeSelfSignedCertificate(publicKeyPKCS1: publicKeyData, commonName: commonName) { tbs in
            guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
                throw IdentityError.signing
            }
            return signature
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            removeKey(tag: tag)
            throw IdentityError.certificate
        }
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            removeKey(tag: tag)
            throw IdentityError.keychain(addStatus)
        }
        guard let identity = loadIdentity(label: label) else {
            removeIdentity(label: label)
            throw IdentityError.notFound
        }
        return identity
    }

    static func loadIdentity(label: String) -> Identity? {
        var certificateRef: CFTypeRef?
        let certStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &certificateRef)
        guard certStatus == errSecSuccess, let certificateRef else { return nil }
        // swiftlint:disable:next force_cast
        let certificate = certificateRef as! SecCertificate

        var identityRef: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &identityRef)
        guard status == errSecSuccess, let identityRef, CFGetTypeID(identityRef) == SecIdentityGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return Identity(identity: identityRef as! SecIdentity, certificate: certificate, label: label)
    }

    static func removeIdentity(label: String) {
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        removeKey(tag: Data(label.utf8))
    }

    private static func removeKey(tag: Data) {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
    }

    // MARK: - Certificate construction

    static func makeSelfSignedCertificate(publicKeyPKCS1: Data, commonName: String, now: Date = .now,
                                          sign: (Data) throws -> Data) throws -> Data {
        let sha256WithRSA = DER.sequence([DER.oid([1, 2, 840, 113549, 1, 1, 11]), DER.null()])
        let rsaEncryption = DER.sequence([DER.oid([1, 2, 840, 113549, 1, 1, 1]), DER.null()])
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8String(commonName)])]),
        ])
        var serial = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F // positive
        if serial[0] == 0 { serial[0] = 0x01 }

        let notBefore = now.addingTimeInterval(-86_400)
        let notAfter = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: 2049, month: 12, day: 31, hour: 23, minute: 59, second: 59).date!

        let tbs = DER.sequence([
            DER.contextSpecific(0, constructed: true, DER.integer(Data([2]))),
            DER.integer(Data(serial)),
            sha256WithRSA,
            name,
            DER.sequence([DER.utcTime(notBefore), DER.utcTime(notAfter)]),
            name,
            DER.sequence([rsaEncryption, DER.bitString(publicKeyPKCS1)]),
            // Extensions: basicConstraints CA=true (matches the reference implementation's client cert).
            DER.contextSpecific(3, constructed: true, DER.sequence([
                DER.sequence([
                    DER.oid([2, 5, 29, 19]),
                    DER.boolean(true),
                    DER.octetString(DER.sequence([DER.boolean(true)])),
                ]),
            ])),
        ])
        let signature = try sign(tbs)
        return DER.sequence([tbs, sha256WithRSA, DER.bitString(signature)])
    }
}

/// Minimal ASN.1 DER encoder/decoder for the structures above and for reading RSA public keys.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func null() -> Data { Data([0x05, 0x00]) }
    static func boolean(_ value: Bool) -> Data { Data([0x01, 0x01, value ? 0xFF : 0x00]) }
    static func octetString(_ content: Data) -> Data { tlv(0x04, content) }
    static func utf8String(_ value: String) -> Data { tlv(0x0C, Data(value.utf8)) }

    static func integer(_ bigEndian: Data) -> Data {
        var bytes = [UInt8](bigEndian)
        while bytes.count > 1, bytes[0] == 0, bytes[1] & 0x80 == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func bitString(_ content: Data) -> Data { tlv(0x03, Data([0]) + content) }

    static func contextSpecific(_ number: UInt8, constructed: Bool, _ content: Data) -> Data {
        tlv((constructed ? 0xA0 : 0x80) | number, content)
    }

    static func oid(_ components: [UInt]) -> Data {
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var stack: [UInt8] = [UInt8(component & 0x7F)]
            var value = component >> 7
            while value > 0 {
                stack.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body.append(contentsOf: stack)
        }
        return tlv(0x06, body)
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }

    /// Parses a PKCS#1 `RSAPublicKey` (SEQUENCE { modulus INTEGER, exponent INTEGER }).
    /// Returns big-endian magnitudes without sign-padding zero bytes.
    static func parseRSAPublicKey(_ data: Data) -> (modulus: Data, exponent: Data)? {
        var index = data.startIndex
        guard let sequence = readTLV(data, &index), sequence.tag == 0x30 else { return nil }
        var inner = sequence.content.startIndex
        guard let modulus = readTLV(sequence.content, &inner), modulus.tag == 0x02,
              let exponent = readTLV(sequence.content, &inner), exponent.tag == 0x02
        else { return nil }
        return (stripLeadingZeros(modulus.content), stripLeadingZeros(exponent.content))
    }

    static func stripLeadingZeros(_ data: Data) -> Data {
        let bytes = Array(data.drop { $0 == 0 })
        return bytes.isEmpty ? Data([0]) : Data(bytes)
    }

    private static func readTLV(_ data: Data, _ index: inout Data.Index) -> (tag: UInt8, content: Data)? {
        guard index < data.endIndex else { return nil }
        let tag = data[index]
        index = data.index(after: index)
        guard index < data.endIndex else { return nil }
        var length = Int(data[index])
        index = data.index(after: index)
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, data.distance(from: index, to: data.endIndex) >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[index])
                index = data.index(after: index)
            }
        }
        guard data.distance(from: index, to: data.endIndex) >= length else { return nil }
        let end = data.index(index, offsetBy: length)
        let content = Data(data[index..<end])
        index = end
        return (tag, content)
    }
}
