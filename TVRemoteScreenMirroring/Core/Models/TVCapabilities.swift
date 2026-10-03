import Foundation

/// Independent abilities of a TV. Support of one never implies support of another.
enum Capability: String, Codable, CaseIterable, Sendable, Identifiable {
    case remoteControl
    case textInput
    case appLaunch
    case photos
    case video
    case screenMirroring
    case powerOff
    case wakeOnNetwork

    var id: String { rawValue }

    /// Capabilities shown in the compatibility check, in display order.
    static let userFacing: [Capability] = [.remoteControl, .textInput, .appLaunch, .photos, .video, .screenMirroring]
}

/// Why a capability is limited or unavailable. Each case maps to a localized explanation.
enum CapabilityNote: String, Codable, Sendable {
    // Remote
    case holdNotSupported
    // Text
    case textNeedsFocusedField
    case textReplaceOnly
    // Apps
    case appListIsCatalog
    case appLaunchUnconfirmed
    // Media
    case noMediaRenderer
    case mediaRendererUnreachable
    case videoFormatLimited
    // Mirroring
    case mirroringNeedsBrowser
    case mirroringNoBrowserOnPlatform
    case mirroringVideoOnlyNoAudio
    /// Legacy value kept only so previously saved TVs still decode; never produced or shown.
    case airPlayAvailable
    // Power
    case wakeNeedsMulticastEntitlement
    case wakeNeedsMacAddress
    case wakeNeedsTVSetting
    // Generic
    case notCheckedYet
    case protocolUnsupported
}

struct CapabilityState: Codable, Hashable, Sendable {
    enum Support: String, Codable, Sendable {
        /// Not determined yet (never "assumed supported").
        case unknown
        /// Protocol and device confirmed the capability during this or an earlier check.
        case supported
        /// Works with an explained limitation.
        case limited
        /// Confirmed as not available on this TV / protocol.
        case unsupported
    }

    var support: Support
    var notes: [CapabilityNote]
    var checkedAt: Date?

    static let unknown = CapabilityState(support: .unknown, notes: [], checkedAt: nil)

    static func supported(_ notes: [CapabilityNote] = [], at date: Date = .now) -> CapabilityState {
        CapabilityState(support: notes.isEmpty ? .supported : .limited, notes: notes, checkedAt: date)
    }

    static func unsupported(_ notes: [CapabilityNote] = [], at date: Date = .now) -> CapabilityState {
        CapabilityState(support: .unsupported, notes: notes, checkedAt: date)
    }

    var isUsable: Bool { support == .supported || support == .limited }
}

struct TVCapabilities: Codable, Hashable, Sendable {
    private var states: [Capability: CapabilityState]

    init(_ states: [Capability: CapabilityState] = [:]) {
        self.states = states
    }

    subscript(_ capability: Capability) -> CapabilityState {
        get { states[capability] ?? .unknown }
        set { states[capability] = newValue }
    }

    /// Merges fresh results; newer checks replace older ones, unknown never overwrites a result.
    mutating func merge(_ other: TVCapabilities) {
        for (capability, state) in other.states where state.support != .unknown || states[capability] == nil {
            states[capability] = state
        }
    }

    var usableCount: Int { Capability.userFacing.filter { self[$0].isUsable }.count }
}
