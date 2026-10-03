import Foundation

/// TV operating-system family. Assigned from protocol evidence (discovery record, device-info
/// endpoint, successful handshake) — never from the brand name alone.
enum TVPlatform: String, Codable, CaseIterable, Sendable {
    case samsungTizen
    case lgWebOS
    case androidTV
    case unknown

    var analyticsValue: String { rawValue }
}

/// Stable identity of a TV. Built from a protocol-provided unique identifier (Samsung device
/// UUID, UPnP UDN, Android TV certificate/Bonjour identity), not from the IP address.
struct TVDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(platform: TVPlatform, uniqueID: String) {
        rawValue = "\(platform.rawValue):\(uniqueID.lowercased())"
    }

    init(rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }
}

/// A TV the user has connected to at least once. Persisted locally.
struct TVDevice: Identifiable, Codable, Hashable, Sendable {
    let id: TVDeviceID
    var platform: TVPlatform
    /// Name the TV reports about itself.
    var reportedName: String
    /// Local name chosen by the user. Renaming never changes the TV's own settings.
    var customName: String?
    var manufacturer: String?
    var modelName: String?
    var osVersion: String?
    /// Last known LAN address. Updated after re-discovery; not part of identity.
    var host: String
    /// Hardware address used only for Wake-on-LAN. Stored locally, never sent to analytics.
    var macAddress: String?
    /// UPnP MediaRenderer description URL, if the TV exposes one.
    var mediaRendererLocation: URL?
    var capabilities: TVCapabilities
    /// TV advertises AirPlay on the network (system Screen Mirroring from Control Center may work).
    var advertisesAirPlay: Bool?
    var addedAt: Date
    var lastConnectedAt: Date?

    var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty { return customName }
        return reportedName
    }

    /// Short model/OS hint that helps tell apart two TVs with the same name.
    var distinguishingDetail: String? {
        [modelName, osVersion].compactMap { $0 }.first
    }
}

/// A TV found on the network during the current discovery run.
struct DiscoveredTV: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable { case bonjour, ssdp, probe, manual }

    let id: TVDeviceID
    var platform: TVPlatform
    var name: String
    var manufacturer: String?
    var modelName: String?
    var osVersion: String?
    var host: String
    var port: UInt16?
    var macAddress: String?
    var mediaRendererLocation: URL?
    var sources: Set<Source>
    /// Evidence gathered during discovery (e.g. AirPlay advertisement).
    var advertisesAirPlay: Bool
    var lastSeen: Date

    mutating func merge(_ other: DiscoveredTV) {
        if platform == .unknown { platform = other.platform }
        if name.isEmpty || name == host { name = other.name }
        manufacturer = manufacturer ?? other.manufacturer
        modelName = modelName ?? other.modelName
        osVersion = osVersion ?? other.osVersion
        host = other.host.isEmpty ? host : other.host
        port = port ?? other.port
        macAddress = macAddress ?? other.macAddress
        mediaRendererLocation = mediaRendererLocation ?? other.mediaRendererLocation
        sources.formUnion(other.sources)
        advertisesAirPlay = advertisesAirPlay || other.advertisesAirPlay
        lastSeen = max(lastSeen, other.lastSeen)
    }
}
