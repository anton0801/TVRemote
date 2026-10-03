import Foundation

/// Contract between the app and the Broadcast Upload Extension (shared App Group).
///
/// The app writes a `MirroringRequest` before showing the system broadcast picker; the
/// extension reads it when the user confirms, serves the receiver page + frame socket on the
/// LAN and publishes `MirroringStatus`. Signals travel as Darwin notifications (no payload);
/// data lives in the App Group defaults.
enum MirroringShared {
    static let appGroupID = "group.app.TVRemoteScreenMirroring"
    static let extensionBundleID = "app.TVRemoteScreenMirroring.BroadcastUpload"
    static let statusChangedNotification = "app.TVRemoteScreenMirroring.mirroring.status"
    static let stopRequestedNotification = "app.TVRemoteScreenMirroring.mirroring.stop"
    /// The user picked another picture profile while mirroring (value in `MirroringQuality.stored`).
    static let qualityChangedNotification = "app.TVRemoteScreenMirroring.mirroring.quality"
    /// A request older than this is ignored (the user started a broadcast from Control Center
    /// without preparing a TV in the app).
    static let requestLifetime: TimeInterval = 10 * 60
    /// The extension refreshes its status this often while running (even on a static screen,
    /// when ReplayKit delivers no frames)…
    static let heartbeatInterval: TimeInterval = 2
    /// …so a status older than this means the extension is gone (e.g. killed by iOS).
    static let heartbeatTimeout: TimeInterval = 8

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Picture profile for screen mirroring (design 45). Each value changes real encoder limits;
/// the extension still lowers them under latency or heat. Only the picture is sent.
enum MirroringQuality: String, Codable, CaseIterable, Sendable {
    case auto, high, dataSaver

    /// Long side of the sent frame, before latency adaptation.
    var maxLongSide: Int {
        switch self {
        case .auto: 1280
        case .high: 1920
        case .dataSaver: 854
        }
    }

    /// The long side never drops below this while adapting to latency.
    var minLongSide: Int {
        switch self {
        case .auto: 854
        case .high: 960
        case .dataSaver: 640
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .auto: 24
        case .high: 30
        case .dataSaver: 15
        }
    }

    /// JPEG quality ceiling (the starting value) and floor while adapting.
    var maxCompressionQuality: Double {
        switch self {
        case .auto: 0.6
        case .high: 0.8
        case .dataSaver: 0.45
        }
    }

    var minCompressionQuality: Double {
        switch self {
        case .auto: 0.35
        case .high: 0.5
        case .dataSaver: 0.3
        }
    }

    private static let key = "mirroring.quality"

    /// The user's choice, shared with the extension through the App Group.
    static var stored: MirroringQuality {
        get { MirroringShared.defaults?.string(forKey: key).flatMap(MirroringQuality.init(rawValue:)) ?? .auto }
        set { MirroringShared.defaults?.set(newValue.rawValue, forKey: key) }
    }
}

struct MirroringRequest: Codable, Equatable, Sendable {
    enum Mode: Codable, Equatable, Sendable {
        /// Remote Pro: no app-imposed time limit.
        case unlimited
        /// Free compatibility check: stop after this many seconds of confirmed display.
        case diagnostic(limitSeconds: Int)
    }

    var sessionID: UUID
    /// Shared secret the receiver page must present (WebSocket subprotocol).
    var token: String
    /// Only this address may connect (the selected TV).
    var tvHost: String
    var mode: Mode
    var createdAt: Date
    /// Language for the receiver page and extension messages.
    var languageCode: String
    var maxLongSide: Int
    var maxFramesPerSecond: Int
    /// Picture profile at start (nil in requests written by older builds = `.auto`).
    var quality: MirroringQuality? = nil
    /// App-side bookkeeping so a session adopted after an app relaunch keeps counting the free
    /// check against the right TV (the extension ignores these).
    var deviceID: String? = nil
    /// Free-check seconds this TV had already used before this session started.
    var usedBeforeSeconds: Double? = nil

    private static let key = "mirroring.request"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        MirroringShared.defaults?.set(data, forKey: Self.key)
    }

    static func load() -> MirroringRequest? {
        guard let data = MirroringShared.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MirroringRequest.self, from: data)
    }

    static func clear() {
        MirroringShared.defaults?.removeObject(forKey: key)
    }

    var isFresh: Bool { Date().timeIntervalSince(createdAt) < MirroringShared.requestLifetime }
}

struct MirroringStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Extension started, opening listeners.
        case starting
        /// Listening; the TV browser has to open the receiver page.
        case waitingForTV
        /// TV connected; waiting for the first displayed frame.
        case connecting
        /// TV confirmed at least one displayed frame.
        case streaming
        case stopped
    }

    enum StopReason: String, Codable, Sendable {
        case userStopped, diagnosticLimit, systemStopped, tvDisconnected, networkLost, thermal, noRequest, tvNeverConnected, failed
    }

    var sessionID: UUID?
    var phase: Phase
    var httpPort: UInt16?
    var pagePath: String?
    var firstFrameAt: Date?
    var framesAcknowledged: Int
    var roundTripMs: Int?
    var frameWidth: Int?
    var frameHeight: Int?
    var stopReason: StopReason?
    var updatedAt: Date

    private static let key = "mirroring.status"

    static let idle = MirroringStatus(sessionID: nil, phase: .stopped, httpPort: nil, pagePath: nil, firstFrameAt: nil,
                                      framesAcknowledged: 0, roundTripMs: nil, frameWidth: nil, frameHeight: nil,
                                      stopReason: nil, updatedAt: .distantPast)

    func publish() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        MirroringShared.defaults?.set(data, forKey: Self.key)
        MirroringShared.post(MirroringShared.statusChangedNotification)
    }

    static func load() -> MirroringStatus? {
        guard let data = MirroringShared.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MirroringStatus.self, from: data)
    }

    /// Seconds of confirmed display so far.
    func confirmedSeconds(now: Date = Date()) -> Double {
        guard let firstFrameAt else { return 0 }
        return max(0, (phase == .stopped ? updatedAt : now).timeIntervalSince(firstFrameAt))
    }
}

/// Binary frame header sent to the receiver page (big-endian):
/// [0] type (1 = JPEG frame) [1] rotation quarter-turns clockwise [2...5] sequence [6...9] phone ms timestamp.
enum MirroringFrameHeader {
    static let size = 10

    static func make(sequence: UInt32, timestampMs: UInt32, quarterTurns: UInt8) -> Data {
        var data = Data([1, quarterTurns])
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMs.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Parses the receiver's acknowledgement text "a:<seq>:<timestamp>".
    static func parseAck(_ text: String) -> (sequence: UInt32, timestampMs: UInt32)? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, parts[0] == "a", let seq = UInt32(parts[1]), let ts = UInt32(parts[2]) else { return nil }
        return (seq, ts)
    }
}
