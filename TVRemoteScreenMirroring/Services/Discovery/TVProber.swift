import Foundation
import Network

/// Identifies a TV at a known address through unicast requests only (no multicast entitlement).
struct TVProber: Sendable {
    /// Quick TCP reachability check.
    static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval = 0.9) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "probe.\(host).\(port)")
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(ceil(timeout))
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .waiting, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    /// Samsung: REST device info on 8001.
    static func probeSamsung(host: String) async -> DiscoveredTV? {
        guard await isPortOpen(host: host, port: 8001),
              let info = try? await SamsungDeviceInfo.fetch(host: host, client: LANHTTPClient(timeout: 2))
        else { return nil }
        return DiscoveredTV(
            id: TVDeviceID(platform: .samsungTizen, uniqueID: info.id),
            platform: .samsungTizen,
            name: info.name,
            manufacturer: "Samsung",
            modelName: info.modelName,
            osVersion: info.os,
            host: host,
            port: 8001,
            macAddress: info.wifiMac,
            mediaRendererLocation: nil,
            sources: [.probe],
            advertisesAirPlay: false,
            lastSeen: .now
        )
    }

    /// LG: SSAP "hello" (no registration, no prompt on the TV) plus unicast SSDP for the UDN.
    static func probeLG(host: String) async -> DiscoveredTV? {
        let open3001 = await isPortOpen(host: host, port: 3001)
        let open3000 = open3001 ? false : await isPortOpen(host: host, port: 3000)
        guard open3001 || open3000 else { return nil }

        var uuid: String?
        var osVersion: String?
        let url = URL(string: open3001 ? "wss://\(host):3001" : "ws://\(host):3000")!
        // Discovery only: the certificate is not pinned here; pinning happens during pairing.
        let client = WebSocketClient(url: url, pinnedFingerprint: nil, allowFirstUse: open3001)
        if (try? await client.connect(timeout: 3)) != nil {
            try? await client.send(#"{"id":"hello","type":"hello","payload":{}}"#)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            // A peer that never answers must not block discovery: closing ends the stream.
            let closer = Task {
                try? await Task.sleep(for: .seconds(2))
                client.close()
            }
            defer { closer.cancel() }
            for await message in client.messages {
                if case .text(let text) = message,
                   let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let payload = json["payload"] as? [String: Any] {
                    uuid = payload["deviceUUID"] as? String
                    osVersion = (payload["deviceOSVersion"] as? String).map { "webOS \($0)" }
                    break
                }
                if ContinuousClock.now > deadline { break }
            }
            client.close()
        }

        var name = "LG TV"
        var model: String?
        var rendererLocation: URL?
        let ssdp = await SSDPClient().search([.lgSecondScreen, .mediaRenderer], host: host, timeout: 1.5)
        for response in ssdp.responses {
            if uuid == nil, let range = response.usn.range(of: "uuid:") {
                uuid = String(response.usn[range.upperBound...].prefix { $0 != ":" })
            }
            if let description = try? await UPnPDeviceDescription.fetch(response.location) {
                if !description.friendlyName.isEmpty { name = description.friendlyName }
                model = model ?? description.modelName
                if description.isMediaRenderer { rendererLocation = response.location }
            }
        }
        guard let uuid, !uuid.isEmpty else { return nil }
        return DiscoveredTV(
            id: TVDeviceID(platform: .lgWebOS, uniqueID: uuid),
            platform: .lgWebOS,
            name: name,
            manufacturer: "LG",
            modelName: model,
            osVersion: osVersion,
            host: host,
            port: open3001 ? 3001 : 3000,
            macAddress: nil,
            mediaRendererLocation: rendererLocation,
            sources: [.probe],
            advertisesAirPlay: false,
            lastSeen: .now
        )
    }

    static func probeAny(host: String) async -> DiscoveredTV? {
        if let samsung = await probeSamsung(host: host) { return samsung }
        return await probeLG(host: host)
    }
}
