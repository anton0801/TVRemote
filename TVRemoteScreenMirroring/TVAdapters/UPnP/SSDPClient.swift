import Darwin
import Foundation

/// SSDP M-SEARCH over a plain UDP socket.
///
/// - Unicast search to one host (`host:1900`) needs only Local Network permission.
/// - Multicast search to 239.255.255.250 requires the managed
///   `com.apple.developer.networking.multicast` entitlement (TN3179). Without it the send
///   fails and `SearchResult.multicastBlocked` is set; discovery then relies on Bonjour and
///   unicast probing instead.
struct SSDPClient: Sendable {
    struct Response: Hashable, Sendable {
        let host: String
        let location: URL
        let searchTarget: String
        let usn: String
        let server: String?
    }

    struct SearchResult: Sendable {
        var responses: [Response]
        var multicastBlocked: Bool
    }

    static let multicastAddress = "239.255.255.250"

    enum Target: String, Sendable {
        case samsungRemote = "urn:samsung.com:device:RemoteControlReceiver:1"
        case lgSecondScreen = "urn:lge-com:service:webos-second-screen:1"
        case mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
        case all = "ssdp:all"
    }

    /// Search. `host == nil` means multicast (entitlement required).
    func search(_ targets: [Target], host: String? = nil, timeout: TimeInterval = 2.5) async -> SearchResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.blockingSearch(targets, host: host, timeout: timeout))
            }
        }
    }

    static func message(for target: Target, unicastHost: String?) -> String {
        let hostHeader = unicastHost.map { "\($0):1900" } ?? "\(multicastAddress):1900"
        return "M-SEARCH * HTTP/1.1\r\nHOST: \(hostHeader)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target.rawValue)\r\nUSER-AGENT: iOS/17 UPnP/1.1 TVRemote/1.0\r\n\r\n"
    }

    /// Parses an SSDP response into a `Response`.
    static func parse(_ text: String, from host: String) -> Response? {
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.uppercased().hasPrefix("HTTP/1.1 200") || status.uppercased().hasPrefix("NOTIFY") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let locationValue = headers["LOCATION"], let location = URL(string: locationValue),
              let locationHost = location.host, LocalNetworkInfo.isPrivateIPv4(locationHost)
        else { return nil }
        return Response(host: host, location: location, searchTarget: headers["ST"] ?? headers["NT"] ?? "",
                        usn: headers["USN"] ?? "", server: headers["SERVER"])
    }

    private static func blockingSearch(_ targets: [Target], host: String?, timeout: TimeInterval) -> SearchResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return SearchResult(responses: [], multicastBlocked: false) }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, host ?? multicastAddress, &destination.sin_addr)

        var multicastBlocked = false
        for target in targets {
            let payload = Array(message(for: target, unicastHost: host).utf8)
            let sent = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0, host == nil { multicastBlocked = true }
        }
        if multicastBlocked { return SearchResult(responses: [], multicastBlocked: true) }

        var responses = Set<Response>()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard poll(&descriptor, 1, remainingMs) > 0 else { break }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &source.sin_addr, &address, socklen_t(INET_ADDRSTRLEN))
            let sourceHost = String(cString: address)
            if let host, sourceHost != host { continue }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            if let response = parse(text, from: sourceHost) { responses.insert(response) }
        }
        return SearchResult(responses: Array(responses), multicastBlocked: false)
    }
}
