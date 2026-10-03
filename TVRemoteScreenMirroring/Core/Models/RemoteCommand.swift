import Foundation

/// Logical remote-control buttons. Adapters map them to protocol keys and report which ones
/// they can actually send.
enum RemoteCommand: String, CaseIterable, Codable, Sendable {
    case up, down, left, right, ok
    case back, home, menu, settings, info, guide, input
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case playPause, play, pause, stop, rewind, fastForward, next, previous
    case powerOff, powerToggle
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9

    static let digits: [RemoteCommand] = [.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9, .digit0]

    /// Commands that make sense to auto-repeat while held.
    var isRepeatable: Bool {
        switch self {
        case .up, .down, .left, .right, .volumeUp, .volumeDown, .channelUp, .channelDown, .rewind, .fastForward:
            return true
        default:
            return false
        }
    }
}

/// How a key is delivered.
enum KeyAction: String, Sendable {
    /// Single press + release.
    case click
    /// Key down (only for protocols with real press/release semantics).
    case press
    /// Key up; must follow every `press`.
    case release
}

/// Text-entry model offered by an adapter. Chosen from capabilities, never by timer.
enum TextInputMode: String, Sendable {
    /// Live typing: protocol can append and delete characters in the focused field (LG webOS).
    case appendAndDelete
    /// Live typing: protocol sets the whole field value at once (Android TV IME batch edit).
    case replaceField
    /// The user composes text on the phone and sends it once (Samsung SendInputString,
    /// whose append/replace semantics are not guaranteed across models).
    case sendCompleted

    var isLive: Bool { self != .sendCompleted }
}

enum TextInputOperation: Equatable, Sendable {
    case append(String)
    case deleteBackward(count: Int)
    case replaceAll(String)
    case submit
}

/// State of the TV's text field as reported by the protocol.
enum TVTextFieldState: Equatable, Sendable {
    case unknown
    case focused
    case notFocused
}

enum AppLaunchOutcome: Equatable, Sendable {
    /// TV reported the app in the foreground.
    case confirmedForeground
    /// TV accepted the command; foreground state could not be confirmed.
    case accepted
}

struct TVAppInfo: Identifiable, Hashable, Codable, Sendable {
    /// Platform-specific app identifier (Tizen app id, webOS id, Android package).
    let id: String
    var title: String
    /// Icon served by the TV itself (LG launch points).
    var iconURL: URL?
    /// Icon path on the TV, fetched through the protocol (Samsung `ed.apps.icon`).
    var iconPath: String? = nil
}
