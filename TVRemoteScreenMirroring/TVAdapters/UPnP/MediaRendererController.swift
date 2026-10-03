import Foundation

/// UPnP AV MediaRenderer (DLNA DMR) control: the TV pulls a file from the phone's local
/// HTTP server. Works across brands when the TV exposes a renderer; capability is decided
/// per TV from its description and `GetProtocolInfo`, never by brand.
actor MediaRendererController {
    struct TransportState: Equatable, Sendable {
        enum State: String, Sendable { case playing, paused, stopped, transitioning, noMedia, unknown }
        var state: State
        var position: TimeInterval?
        var duration: TimeInterval?
    }

    struct SinkSupport: Equatable, Sendable {
        var jpeg: Bool
        var mp4: Bool
        var reported: Bool
    }

    private let avTransport: URL
    private let renderingControl: URL?
    private let connectionManager: URL?
    private let http = LANHTTPClient(timeout: 6)
    let description: UPnPDeviceDescription

    init?(description: UPnPDeviceDescription) {
        guard let transport = description.service(containing: "AVTransport") else { return nil }
        self.description = description
        avTransport = transport.controlURL
        renderingControl = description.service(containing: "RenderingControl")?.controlURL
        connectionManager = description.service(containing: "ConnectionManager")?.controlURL
    }

    /// Finds the renderer on a known TV host via unicast SSDP (no multicast entitlement needed).
    static func locate(host: String, knownLocation: URL?) async -> MediaRendererController? {
        if let knownLocation, let description = try? await UPnPDeviceDescription.fetch(knownLocation),
           let controller = MediaRendererController(description: description) {
            return controller
        }
        let result = await SSDPClient().search([.mediaRenderer], host: host, timeout: 2)
        for response in result.responses {
            if let description = try? await UPnPDeviceDescription.fetch(response.location),
               let controller = MediaRendererController(description: description) {
                return controller
            }
        }
        return nil
    }

    func sinkSupport() async -> SinkSupport {
        guard let connectionManager,
              let body = try? await soap(connectionManager, service: "urn:schemas-upnp-org:service:ConnectionManager:1", action: "GetProtocolInfo", arguments: [])
        else { return SinkSupport(jpeg: true, mp4: true, reported: false) }
        let sink = (XMLValueExtractor.value(of: "Sink", in: body) ?? "").lowercased()
        guard !sink.isEmpty else { return SinkSupport(jpeg: true, mp4: true, reported: false) }
        return SinkSupport(jpeg: sink.contains("image/jpeg"), mp4: sink.contains("video/mp4"), reported: true)
    }

    func load(url: URL, mimeType: String, title: String, isImage: Bool) async throws {
        let metadata = DIDL.metadata(url: url, mimeType: mimeType, title: title, isImage: isImage)
        _ = try? await soap(avTransport, action: "Stop", arguments: [("InstanceID", "0")])
        _ = try await soap(avTransport, action: "SetAVTransportURI", arguments: [
            ("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata),
        ])
        try await play()
    }

    func play() async throws {
        _ = try await soap(avTransport, action: "Play", arguments: [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        _ = try await soap(avTransport, action: "Pause", arguments: [("InstanceID", "0")])
    }

    func stop() async throws {
        _ = try await soap(avTransport, action: "Stop", arguments: [("InstanceID", "0")])
    }

    func seek(to seconds: TimeInterval) async throws {
        _ = try await soap(avTransport, action: "Seek", arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.timeString(seconds))])
    }

    func transportState() async throws -> TransportState {
        let info = try await soap(avTransport, action: "GetTransportInfo", arguments: [("InstanceID", "0")])
        let raw = XMLValueExtractor.value(of: "CurrentTransportState", in: info) ?? ""
        let state: TransportState.State
        switch raw.uppercased() {
        case "PLAYING": state = .playing
        case "PAUSED_PLAYBACK": state = .paused
        case "STOPPED": state = .stopped
        case "TRANSITIONING": state = .transitioning
        case "NO_MEDIA_PRESENT": state = .noMedia
        default: state = .unknown
        }
        var result = TransportState(state: state, position: nil, duration: nil)
        if let position = try? await soap(avTransport, action: "GetPositionInfo", arguments: [("InstanceID", "0")]) {
            result.position = XMLValueExtractor.value(of: "RelTime", in: position).flatMap(Self.parseTime)
            result.duration = XMLValueExtractor.value(of: "TrackDuration", in: position).flatMap(Self.parseTime)
        }
        return result
    }

    // MARK: SOAP

    private func soap(_ url: URL, service: String = "urn:schemas-upnp-org:service:AVTransport:1", action: String, arguments: [(String, String)]) async throws -> String {
        let args = arguments.map { "<\($0.0)>\(XMLEscape.escape($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        let response = try await http.request(url, method: "POST", headers: [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPAction": "\"\(service)#\(action)\"",
        ], body: Data(envelope.utf8))
        let body = String(decoding: response.body, as: UTF8.self)
        guard (200..<300).contains(response.status) else {
            if body.contains("714") || body.contains("Illegal MIME") || body.contains("701") { throw AppError.mediaFormatUnsupported }
            throw AppError.mediaPlaybackFailed
        }
        return body
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func parseTime(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").map { Double($0.split(separator: ".").first ?? "") }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let s = parts[2] else { return nil }
        let total = h * 3600 + m * 60 + s
        return total > 0 ? total : nil
    }
}

enum DIDL {
    static func metadata(url: URL, mimeType: String, title: String, isImage: Bool) -> String {
        let itemClass = isImage ? "object.item.imageItem.photo" : "object.item.videoItem"
        let protocolInfo = "http-get:*:\(mimeType):\(isImage ? "DLNA.ORG_PN=JPEG_LRG;" : "")DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(XMLEscape.escape(title))</dc:title><upnp:class>\(itemClass)</upnp:class><res protocolInfo="\(protocolInfo)">\(XMLEscape.escape(url.absoluteString))</res></item></DIDL-Lite>
        """
    }
}

enum XMLEscape {
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum XMLValueExtractor {
    /// Value of the first element named `name` (namespace prefix ignored).
    static func value(of name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?\(name)(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_]+:)?\(name)>") else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        return XMLEscape.unescape(String(xml[valueRange]))
    }
}
