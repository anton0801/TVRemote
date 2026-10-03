#if DEBUG
import Foundation

/// DEBUG-only simulated TV used for UI tests and visual QA in the Simulator (which has no
/// TVs on its network). Compiled out of release builds; activated only with the `-DemoTV`
/// launch argument and never shown in discovery results.
actor DemoTVSession: TVSession {
    static let demoID = TVDeviceID(platform: .lgWebOS, uniqueID: "debug-demo-tv")

    nonisolated let deviceID = DemoTVSession.demoID
    nonisolated let platform: TVPlatform = .lgWebOS
    nonisolated let events: AsyncStream<TVSessionEvent>
    nonisolated let supportedCommands = Set(RemoteCommand.allCases).subtracting([.playPause, .powerToggle])
    nonisolated let textInputMode: TextInputMode? = .appendAndDelete
    nonisolated let canListInstalledApps = true
    nonisolated let canOpenBrowser = true
    private let continuation: AsyncStream<TVSessionEvent>.Continuation

    init() {
        let channel = EventChannel<TVSessionEvent>()
        events = channel.stream
        continuation = channel.continuation
        continuation.yield(.textField(.focused))
    }

    static var device: TVDevice {
        TVDevice(id: demoID, platform: .lgWebOS, reportedName: "Demo TV (debug build)", customName: nil, manufacturer: "Demo",
                 modelName: "Simulator", osVersion: "webOS (simulated)", host: "127.0.0.1", macAddress: nil,
                 mediaRendererLocation: nil, capabilities: TVCapabilities(), advertisesAirPlay: true, addedAt: .now, lastConnectedAt: .now)
    }

    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool { false }
    func send(_ command: RemoteCommand, action: KeyAction) async throws {}
    func performText(_ operation: TextInputOperation) async throws {}
    func installedApps() async throws -> [TVAppInfo] {
        [TVAppInfo(id: "netflix", title: "Netflix"), TVAppInfo(id: "youtube.leanback.v4", title: "YouTube"),
         TVAppInfo(id: "amazon", title: "Prime Video"), TVAppInfo(id: "com.disney.disneyplus-prod", title: "Disney+"),
         TVAppInfo(id: "com.webos.app.browser", title: "Web Browser")]
    }
    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome { .confirmedForeground }
    func launch(appID: String) async throws -> AppLaunchOutcome { .confirmedForeground }
    func openBrowser(url: URL) async throws {}
    func appIconData(for app: TVAppInfo) async -> Data? { nil }
    func close() async { continuation.finish() }
}

extension TVAppInfo {
    init(id: String, title: String) {
        self.init(id: id, title: title, iconURL: nil, iconPath: nil)
    }
}

extension ConnectionManager {
    /// Attaches the simulated TV (DEBUG + `-DemoTV` only).
    func attachDemoTV(devices: DeviceStore) {
        let device = DemoTVSession.device
        devices.upsert(device)
        devices.select(device.id)
        attachForDebug(DemoTVSession(), device: device)
    }
}
#endif
