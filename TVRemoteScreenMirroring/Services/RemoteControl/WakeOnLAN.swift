import Darwin
import Foundation

/// Wake-on-LAN magic packet. UDP *broadcast* on iOS requires the managed multicast
/// entitlement (TN3179); without it the send is refused and we report that honestly
/// instead of pretending the TV was switched on. Success of the send never means the TV woke up.
enum WakeOnLAN {
    enum Outcome: Equatable {
        /// Packet handed to the network; the TV may or may not wake (setting-dependent).
        case sent
        /// iOS refused broadcast (entitlement not granted) or no network.
        case notPermitted
        case invalidMAC
    }

    static func magicPacket(mac: String) -> Data? {
        let hex = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard hex.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: hex) }
        return packet
    }

    static func send(mac: String, lastKnownHost: String?) async -> Outcome {
        guard let packet = magicPacket(mac: mac) else { return .invalidMAC }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blockingSend(packet, lastKnownHost: lastKnownHost))
            }
        }
    }

    private static func blockingSend(_ packet: Data, lastKnownHost: String?) -> Outcome {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .notPermitted }
        defer { close(fd) }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255"]
        if let info = LocalNetworkInfo.current(), let own = LocalNetworkInfo.octets(info.address), let mask = LocalNetworkInfo.octets(info.netmask) {
            targets.append(zip(own, mask).map { String($0 | ~$1) }.joined(separator: "."))
        }
        var anySent = false
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, target, &address.sin_addr)
            let result = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if result > 0 { anySent = true }
        }
        return anySent ? .sent : .notPermitted
    }
}
