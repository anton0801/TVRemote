import CryptoKit
import Foundation
import Security

/// Trust model for TVs that serve self-signed TLS certificates (Samsung 8002, LG 3001,
/// Android TV 6466/6467): trust-on-first-use pinning.
///
/// - During pairing (user sees and confirms the prompt on the TV) the leaf certificate
///   fingerprint is recorded, but only for hosts on a private LAN range.
/// - Every later connection must present the same certificate; a mismatch fails closed with
///   `AppError.tlsIdentityMismatch` and asks the user to pair again.
/// ATS is not disabled globally; only `NSAllowsLocalNetworking` is set.
enum CertificatePinning {
    static func sha256Fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    enum Decision: Equatable {
        case accept(fingerprint: String)
        case reject
    }

    /// Pure decision function (unit-tested).
    static func evaluate(host: String, presentedFingerprint: String?, pinned: String?, allowFirstUse: Bool) -> Decision {
        guard let presentedFingerprint else { return .reject }
        if let pinned {
            return pinned == presentedFingerprint ? .accept(fingerprint: presentedFingerprint) : .reject
        }
        guard allowFirstUse, LocalNetworkInfo.isPrivateIPv4(host) else { return .reject }
        return .accept(fingerprint: presentedFingerprint)
    }
}

/// URLSession delegate applying `CertificatePinning` for one host.
final class PinningSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String
    private let pinned: String?
    private let allowFirstUse: Bool
    private let lock = NSLock()
    private var _observedFingerprint: String?
    private var _rejected = false

    init(host: String, pinned: String?, allowFirstUse: Bool) {
        self.host = host
        self.pinned = pinned
        self.allowFirstUse = allowFirstUse
    }

    var observedFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return _observedFingerprint
    }

    var wasRejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _rejected
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == host
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fingerprint = CertificatePinning.leafCertificate(of: trust).map(CertificatePinning.sha256Fingerprint)
        switch CertificatePinning.evaluate(host: host, presentedFingerprint: fingerprint, pinned: pinned, allowFirstUse: allowFirstUse) {
        case .accept(let value):
            lock.lock(); _observedFingerprint = value; lock.unlock()
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject:
            lock.lock(); _rejected = true; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
