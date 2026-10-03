import Foundation

/// Events pushed by a connected TV.
enum TVSessionEvent: Sendable, Equatable {
    case disconnected(AppError?)
    case textField(TVTextFieldState)
    case foregroundApp(String?)
    case power(isOn: Bool)
    case volume(level: Int, max: Int, muted: Bool)
}

/// A live, authenticated connection to one TV. Implemented by protocol adapters; contains no UI.
/// Every session belongs to exactly one device; commands for another device never reach it.
protocol TVSession: AnyObject, Sendable {
    nonisolated var deviceID: TVDeviceID { get }
    nonisolated var platform: TVPlatform { get }
    nonisolated var events: AsyncStream<TVSessionEvent> { get }

    /// Commands this protocol can actually deliver.
    nonisolated var supportedCommands: Set<RemoteCommand> { get }
    /// True when the protocol has real key-down/key-up semantics for the command.
    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool
    func send(_ command: RemoteCommand, action: KeyAction) async throws

    nonisolated var textInputMode: TextInputMode? { get }
    func performText(_ operation: TextInputOperation) async throws

    /// Whether the TV can report its installed apps.
    nonisolated var canListInstalledApps: Bool { get }
    func installedApps() async throws -> [TVAppInfo]
    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome
    func launch(appID: String) async throws -> AppLaunchOutcome
    /// The app's icon as provided by the TV (nil if the protocol doesn't offer icons).
    func appIconData(for app: TVAppInfo) async -> Data?

    /// Whether the TV has a web browser we can open with a URL (used as mirroring receiver).
    nonisolated var canOpenBrowser: Bool { get }
    func openBrowser(url: URL) async throws

    func close() async
}

/// UI hooks used during first-time pairing.
@MainActor
protocol PairingInteraction: AnyObject {
    /// The TV is showing an Allow/Accept prompt.
    func showConfirmOnTV()
    /// The TV shows a code; returns what the user typed. Throws `CancellationError` if dismissed.
    func requestPIN(attempt: Int) async throws -> String
}

struct ConnectionTarget: Sendable, Hashable {
    var id: TVDeviceID
    var platform: TVPlatform
    var host: String
    var name: String
    var macAddress: String?
}

/// Result of a successful connect: the session plus refreshed identity details.
struct ConnectResult: Sendable {
    let session: any TVSession
    let credentials: TVCredentials
    let deviceInfo: DeviceInfoUpdate
}

struct DeviceInfoUpdate: Sendable, Equatable {
    var reportedName: String?
    var manufacturer: String?
    var modelName: String?
    var osVersion: String?
    var macAddress: String?
    var powerIsOn: Bool?
}

protocol TVConnector: Sendable {
    var platform: TVPlatform { get }
    /// Connects with stored credentials, or performs first-time pairing through `interaction`.
    func connect(_ target: ConnectionTarget, credentials: TVCredentials?, interaction: PairingInteraction) async throws -> ConnectResult
}

/// Helper to build an `AsyncStream` with an externally held continuation.
struct EventChannel<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>
    let continuation: AsyncStream<Element>.Continuation

    /// `buffer: nil` never drops elements (required for byte streams with framing).
    init(buffer: Int? = 32) {
        var continuation: AsyncStream<Element>.Continuation!
        stream = AsyncStream(bufferingPolicy: buffer.map { .bufferingNewest($0) } ?? .unbounded) { continuation = $0 }
        self.continuation = continuation
    }
}
