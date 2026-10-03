import Foundation

/// Samsung Tizen (2016+) remote-control protocol over WebSocket.
///
/// Sources (see COMPATIBILITY.md): samsungtvws, ha-samsungtv-smart, Home Assistant fixtures.
/// The protocol is not officially documented by Samsung; every capability stays
/// "implemented but unverified" until tested on a physical TV.
struct SamsungConnector: TVConnector {
    let platform: TVPlatform = .samsungTizen
    let clientName = "TV Remote iOS"

    func connect(_ target: ConnectionTarget, credentials: TVCredentials?, interaction: PairingInteraction) async throws -> ConnectResult {
        let info = try? await SamsungDeviceInfo.fetch(host: target.host)
        // DHCP may have given this address to another TV: never pair or send keys to it.
        if let info, TVDeviceID(platform: .samsungTizen, uniqueID: info.id) != target.id {
            throw AppError.deviceUnreachable
        }
        let useTLS = info?.tokenAuthSupport ?? true
        let encodedName = Data(clientName.utf8).base64EncodedString()

        func makeURL(tls: Bool) -> URL {
            var components = URLComponents()
            components.scheme = tls ? "wss" : "ws"
            components.host = target.host
            components.port = tls ? 8002 : 8001
            components.path = "/api/v2/channels/samsung.remote.control"
            var items = [URLQueryItem(name: "name", value: encodedName)]
            if tls, let token = credentials?.token { items.append(URLQueryItem(name: "token", value: token)) }
            components.queryItems = items
            return components.url!
        }

        let pinned = credentials?.pinnedCertificateSHA256
        var client = WebSocketClient(url: makeURL(tls: useTLS), pinnedFingerprint: pinned, allowFirstUse: pinned == nil)
        do {
            try await client.connect()
        } catch let error as AppError where error == .tlsIdentityMismatch {
            throw error
        } catch {
            guard useTLS, info == nil else { throw AppError.deviceUnreachable }
            // Older models without token auth listen only on 8001.
            client = WebSocketClient(url: makeURL(tls: false), pinnedFingerprint: nil, allowFirstUse: false)
            try await client.connect()
        }

        let token: String?
        do {
            token = try await awaitAuthorization(client: client, hasToken: credentials?.token != nil, interaction: interaction)
        } catch {
            client.close() // don't leave the socket (and the TV's Allow prompt) behind
            throw error
        }
        var newCredentials = credentials ?? TVCredentials()
        if let token { newCredentials.token = token }
        if let fingerprint = client.observedFingerprint { newCredentials.pinnedCertificateSHA256 = fingerprint }

        let session = SamsungSession(deviceID: target.id, host: target.host, client: client)
        await session.start()
        let update = DeviceInfoUpdate(
            reportedName: info?.name,
            manufacturer: "Samsung",
            modelName: info?.modelName,
            osVersion: info?.os,
            macAddress: info?.wifiMac,
            powerIsOn: info?.powerState.map { $0 == "on" }
        )
        return ConnectResult(session: session, credentials: newCredentials, deviceInfo: update)
    }

    /// Waits for `ms.channel.connect` (authorized) or `ms.channel.unauthorized` (denied on TV).
    private func awaitAuthorization(client: WebSocketClient, hasToken: Bool, interaction: PairingInteraction) async throws -> String? {
        let promptTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(hasToken ? 2500 : 700))
            interaction.showConfirmOnTV()
        }
        defer { promptTask.cancel() }

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await message in client.messages {
                    guard case .text(let text) = message,
                          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let event = json["event"] as? String
                    else { continue }
                    switch event {
                    case "ms.channel.connect":
                        let data = json["data"] as? [String: Any]
                        if let token = data?["token"] as? String { return token }
                        if let token = data?["token"] as? NSNumber { return token.stringValue }
                        return nil
                    case "ms.channel.unauthorized":
                        throw AppError.pairingRejected
                    case "ms.channel.timeOut":
                        throw AppError.pairingTimedOut
                    default:
                        continue
                    }
                }
                throw AppError.pairingRejected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw AppError.pairingTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AppError.pairingTimedOut }
            return result
        }
    }
}

/// Parsed `GET http://<tv>:8001/api/v2/`.
struct SamsungDeviceInfo: Equatable, Sendable {
    var id: String
    var name: String
    var modelName: String?
    var os: String?
    var wifiMac: String?
    var tokenAuthSupport: Bool?
    var powerState: String?

    static func fetch(host: String, client: LANHTTPClient = LANHTTPClient(timeout: 3)) async throws -> SamsungDeviceInfo {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { throw AppError.deviceUnreachable }
        return try parse(try await client.json(url))
    }

    static func parse(_ json: [String: Any]) throws -> SamsungDeviceInfo {
        let device = json["device"] as? [String: Any] ?? [:]
        let rawID = (device["duid"] as? String) ?? (json["id"] as? String) ?? (device["id"] as? String)
        guard let rawID, !rawID.isEmpty else { throw AppError.deviceUnreachable }
        let id = rawID.replacingOccurrences(of: "uuid:", with: "")
        let name = ((device["name"] as? String) ?? (json["name"] as? String) ?? "Samsung TV")
            .replacingOccurrences(of: "[TV] ", with: "")
        func bool(_ key: String) -> Bool? {
            (device[key] as? String).map { $0.lowercased() == "true" } ?? (device[key] as? Bool)
        }
        return SamsungDeviceInfo(
            id: id,
            name: name,
            modelName: device["modelName"] as? String,
            os: device["OS"] as? String,
            wifiMac: (device["wifiMac"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            tokenAuthSupport: bool("TokenAuthSupport"),
            powerState: device["PowerState"] as? String
        )
    }
}

actor SamsungSession: TVSession {
    nonisolated let deviceID: TVDeviceID
    nonisolated let platform: TVPlatform = .samsungTizen
    nonisolated let events: AsyncStream<TVSessionEvent>
    nonisolated let supportedCommands: Set<RemoteCommand> = Set(SamsungKeys.map.keys)
    nonisolated let textInputMode: TextInputMode? = .sendCompleted
    nonisolated let canListInstalledApps = true
    nonisolated let canOpenBrowser = true

    private let host: String
    private let client: WebSocketClient
    private let eventContinuation: AsyncStream<TVSessionEvent>.Continuation
    private var readerTask: Task<Void, Never>?
    /// Waiters per event. Samsung replies carry no request ID, so a waiter may add a matcher
    /// (e.g. the icon path) and each waiter has its own timeout.
    private struct Waiter {
        let id: UUID
        let matches: (@Sendable ([String: Any]) -> Bool)?
        let continuation: CheckedContinuation<[String: Any], Error>
    }
    private var pending: [String: [Waiter]] = [:]
    /// Icon requests go one at a time so replies can't be handed to the wrong app.
    private var iconQueue: Task<Data?, Never>?
    private var imeSessionAnnounced = false
    private var appTypes: [String: Int] = [:]
    private var closed = false

    init(deviceID: TVDeviceID, host: String, client: WebSocketClient) {
        self.deviceID = deviceID
        self.host = host
        self.client = client
        let channel = EventChannel<TVSessionEvent>()
        events = channel.stream
        eventContinuation = channel.continuation
    }

    func start() {
        client.onClose { [weak self] error in
            Task { await self?.handleClosed(error) }
        }
        readerTask = Task { [client, weak self] in
            for await message in client.messages {
                guard case .text(let text) = message,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { continue }
                await self?.handle(json)
            }
        }
    }

    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool {
        command.isRepeatable
    }

    func send(_ command: RemoteCommand, action: KeyAction) async throws {
        guard let key = SamsungKeys.map[command] else { throw AppError.commandNotSupported }
        let cmd: String
        switch action {
        case .click: cmd = "Click"
        case .press: cmd = "Press"
        case .release: cmd = "Release"
        }
        try await sendJSON([
            "method": "ms.remote.control",
            "params": ["Cmd": cmd, "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    func performText(_ operation: TextInputOperation) async throws {
        switch operation {
        case .replaceAll(let text), .append(let text):
            if !imeSessionAnnounced {
                // Some models require this broadcast before accepting text.
                try await sendJSON(["method": "ms.channel.emit", "params": ["event": "custom.remote.textReceived", "to": "broadcast"]])
                imeSessionAnnounced = true
            }
            try await sendJSON([
                "method": "ms.remote.control",
                "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"],
            ])
        case .submit:
            try await sendJSON(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
            imeSessionAnnounced = false
        case .deleteBackward:
            try await send(.back, action: .click)
        }
    }

    func installedApps() async throws -> [TVAppInfo] {
        let response = try await request(event: "ed.installedApp.get", payload: [
            "method": "ms.channel.emit",
            "params": ["event": "ed.installedApp.get", "to": "host"],
        ])
        let list = ((response["data"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["appId"] as? String, let name = item["name"] as? String else { return nil }
            if let type = item["app_type"] as? Int { appTypes[id] = type }
            return TVAppInfo(id: id, title: name, iconURL: nil, iconPath: item["icon"] as? String)
        }
    }

    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome {
        var lastError: Error = AppError.appNotInstalled
        for id in app.samsungIDs {
            do { return try await launch(appID: id) } catch { lastError = error }
        }
        throw lastError
    }

    func launch(appID: String) async throws -> AppLaunchOutcome {
        let actionType = appTypes[appID] == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK"
        let response = try await request(event: "ed.apps.launch", payload: [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host", "data": ["appId": appID, "action_type": actionType, "metaTag": ""]],
        ])
        guard Self.isSuccess(response["data"]) else { throw AppError.appLaunchFailed }
        return await confirmForeground(appID: appID)
    }

    /// Icon bytes of an installed app, requested from the TV (`ed.apps.icon`, base64 PNG).
    func appIconData(for app: TVAppInfo) async -> Data? {
        guard let path = app.iconPath, !path.isEmpty, !closed else { return nil }
        let previous = iconQueue
        let task = Task { () -> Data? in
            _ = await previous?.value
            return await self.fetchIcon(path: path)
        }
        iconQueue = task
        return await task.value
    }

    private func fetchIcon(path: String) async -> Data? {
        guard let response = try? await request(event: "ed.apps.icon", payload: [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.icon", "to": "host", "data": ["iconPath": path]],
        ], timeout: .seconds(4), matches: { json in
            // When the TV echoes the path, only accept the reply for this icon.
            guard let echoed = (json["data"] as? [String: Any])?["iconPath"] as? String else { return true }
            return echoed == path
        }),
              let base64 = (response["data"] as? [String: Any])?["imageBase64"] as? String
        else { return nil }
        return Data(base64Encoded: base64)
    }

    func openBrowser(url: URL) async throws {
        for id in TVAppCatalog.samsungBrowserIDs {
            let response = try? await request(event: "ed.apps.launch", payload: [
                "method": "ms.channel.emit",
                "params": ["event": "ed.apps.launch", "to": "host", "data": ["appId": id, "action_type": "NATIVE_LAUNCH", "metaTag": url.absoluteString]],
            ])
            if let response, Self.isSuccess(response["data"]) { return }
        }
        throw AppError.mirroringBrowserLaunchFailed
    }

    func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        client.close()
        failPending(AppError.connectionLost)
        eventContinuation.finish()
    }

    // MARK: Private

    private static func isSuccess(_ value: Any?) -> Bool {
        if let number = value as? Int { return number == 200 }
        if let string = value as? String { return string == "200" }
        return false
    }

    /// Asks the REST API whether the app became visible (real confirmation where supported).
    private func confirmForeground(appID: String) async -> AppLaunchOutcome {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/\(appID)") else { return .accepted }
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(900))
            if let json = try? await LANHTTPClient(timeout: 2).json(url), (json["visible"] as? Bool) == true {
                return .confirmedForeground
            }
        }
        return .accepted
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard !closed else { throw AppError.connectionLost }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await client.send(String(decoding: data, as: UTF8.self))
    }

    /// Registers the waiter *before* sending so a fast reply can't be missed.
    private func request(event: String, payload: [String: Any], timeout: Duration = .seconds(5),
                         matches: (@Sendable ([String: Any]) -> Bool)? = nil) async throws -> [String: Any] {
        guard !closed else { throw AppError.connectionLost }
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[event, default: []].append(Waiter(id: id, matches: matches, continuation: continuation))
            Task { [weak self] in
                do {
                    try await self?.client.send(text)
                } catch {
                    await self?.resolve(event: event, id: id, with: .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(event: event, id: id, with: .failure(AppError.commandTimedOut))
            }
        }
    }

    /// Resumes one specific waiter exactly once (reply, send failure or its own timeout).
    private func resolve(event: String, id: UUID, with result: Result<[String: Any], Error>) {
        guard var waiters = pending[event], let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        pending[event] = waiters
        waiter.continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let all = pending.values.flatMap { $0 }
        pending.removeAll()
        all.forEach { $0.continuation.resume(throwing: error) }
    }

    private func handle(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        if let waiter = pending[event]?.first(where: { $0.matches?(json) ?? true }) {
            resolve(event: event, id: waiter.id, with: .success(json))
            return
        }
        switch event {
        case "ms.remote.imeStart":
            eventContinuation.yield(.textField(.focused))
        case "ms.remote.imeEnd", "ms.remote.imeDone":
            imeSessionAnnounced = false
            eventContinuation.yield(.textField(.notFocused))
        default:
            break
        }
    }

    private func handleClosed(_ error: Error?) {
        guard !closed else { return }
        closed = true
        failPending(AppError.connectionLost)
        eventContinuation.yield(.disconnected(.connectionLost))
        eventContinuation.finish()
    }
}

enum SamsungKeys {
    static let map: [RemoteCommand: String] = {
        var map: [RemoteCommand: String] = [
            .up: "KEY_UP", .down: "KEY_DOWN", .left: "KEY_LEFT", .right: "KEY_RIGHT", .ok: "KEY_ENTER",
            .back: "KEY_RETURN", .home: "KEY_HOME", .menu: "KEY_MENU", .info: "KEY_INFO", .guide: "KEY_GUIDE",
            .input: "KEY_SOURCE", .volumeUp: "KEY_VOLUP", .volumeDown: "KEY_VOLDOWN", .mute: "KEY_MUTE",
            .channelUp: "KEY_CHUP", .channelDown: "KEY_CHDOWN", .play: "KEY_PLAY", .pause: "KEY_PAUSE",
            .stop: "KEY_STOP", .rewind: "KEY_REWIND", .fastForward: "KEY_FF", .powerToggle: "KEY_POWER",
        ]
        for (index, digit) in RemoteCommand.digits.enumerated() {
            map[digit] = "KEY_\((index + 1) % 10)"
        }
        return map
    }()
}
