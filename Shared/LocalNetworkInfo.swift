import Foundation
import Darwin

/// IPv4 information about the phone's Wi-Fi interface.
struct LocalNetworkInfo: Equatable, Sendable {
    let address: String
    let netmask: String
    let interfaceName: String

    /// Current Wi-Fi (en0) IPv4 address, or any private IPv4 on an active non-loopback interface.
    static func current() -> LocalNetworkInfo? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [LocalNetworkInfo] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard let address = ipv4String(addr), let netmask = ipv4String(mask) else { continue }
            candidates.append(LocalNetworkInfo(address: address, netmask: netmask, interfaceName: name))
        }
        return candidates.first { $0.interfaceName == "en0" }
            ?? candidates.first { $0.isPrivate && !$0.interfaceName.hasPrefix("utun") && !$0.interfaceName.hasPrefix("pdp_ip") }
    }

    var isPrivate: Bool { Self.isPrivateIPv4(address) }

    /// Hosts of the local subnet, capped to the /24 around the phone's own address to keep
    /// scanning bounded on large networks.
    func scanCandidates() -> [String] {
        guard let own = Self.octets(address), let mask = Self.octets(netmask) else { return [] }
        let prefix = mask.reduce(0) { $0 + $1.nonzeroBitCount }
        if prefix >= 24 {
            let base = zip(own, mask).map { $0 & $1 }
            let hostCount = 1 << (32 - prefix)
            return (1..<max(hostCount - 1, 1)).compactMap { offset -> String? in
                let last = Int(base[3]) + offset
                guard last < 255 else { return nil }
                let host = "\(base[0]).\(base[1]).\(base[2]).\(last)"
                return host == address ? nil : host
            }
        }
        return (1...254).map { "\(own[0]).\(own[1]).\(own[2]).\($0)" }.filter { $0 != address }
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        guard let o = octets(host) else { return false }
        switch (o[0], o[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    static func octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    private static func ipv4String(_ sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(sockaddrPointer, socklen_t(sockaddrPointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? String(cString: buffer) : nil
    }
}
