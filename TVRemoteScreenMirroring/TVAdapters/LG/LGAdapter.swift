import Foundation

/// LG webOS second-screen protocol (SSAP) over WebSocket.
///
/// Sources (COMPATIBILITY.md): aiowebostv (unsigned manifest after the webOS 26 change),
/// ConnectSDK, PyWebOSTV, webOS OSE docs. Not an official LG SDK for iOS; unverified until
/// tested on physical TVs.
struct LGConnector: TVConnector {
    let platform: TVPlatform = .lgWebOS

    func connect(_ target: ConnectionTarget, credentials: TVCredentials?, interaction: PairingInteraction) async throws -> ConnectResult {
        let pinned = credentials?.pinnedCertificateSHA256
        let preferredPort: UInt16 = credentials?.portHint ?? 3001
        let ports: [UInt16] = preferredPort == 3000 ? [3000, 3001] : [3001, 3000]

        var connected: (WebSocketClient, UInt16)?
        var lastError: Error = AppError.deviceUnreachable
        for port in ports {
            let secure = port == 3001
            guard let url = URL(string: "\(secure ? "wss" : "ws")://\(target.host):\(port)") else { continue }
            let client = WebSocketClient(url: url, pinnedFingerprint: secure ? pinned : nil, allowFirstUse: secure && pinned == nil)
            do {
                try await client.connect(timeout: 6)
                connected = (client, port)
                break
            } catch let error as AppError where error == .tlsIdentityMismatch {
                throw error
            } catch {
                lastError = error
            }
        }
        guard let (client, port) = connected else { throw AppError.wrap(lastError) }

        let channel = LGMessageChannel(client: client)
        await channel.start()

        let hello = try? await channel.call(type: "hello", uri: nil, payload: [:], timeout: .seconds(3))
        let helloPayload = hello?["payload"] as? [String: Any]
        // Another TV at this address (DHCP change): don't register with it.
        if let uuid = helloPayload?["deviceUUID"] as? String, !uuid.isEmpty,
           TVDeviceID(platform: .lgWebOS, uniqueID: uuid) != target.id {
            client.close()
            throw AppError.deviceUnreachable
        }
        _ = try? await channel.call(type: "request", uri: "ssap://system/getSystemInfo", payload: [:], timeout: .seconds(3))

        let clientKey: String
        do {
            clientKey = try await register(channel: channel, clientKey: credentials?.token, interaction: interaction)
        } catch {
            client.close()
            throw error
        }

        var credentialsOut = credentials ?? TVCredentials()
        credentialsOut.token = clientKey
        credentialsOut.portHint = port
        if let fingerprint = client.observedFingerprint { credentialsOut.pinnedCertificateSHA256 = fingerprint }

        let systemInfo = (try? await channel.call(type: "request", uri: "ssap://system/getSystemInfo", payload: [:], timeout: .seconds(3)))?["payload"] as? [String: Any]
        let softwareInfo = (try? await channel.call(type: "request", uri: "ssap://com.webos.service.update/getCurrentSWInformation", payload: [:], timeout: .seconds(3)))?["payload"] as? [String: Any]
        let networkInfo = (try? await channel.call(type: "request", uri: "ssap://com.webos.service.connectionmanager/getinfo", payload: [:], timeout: .seconds(3)))?["payload"] as? [String: Any]

        let session = LGSession(deviceID: target.id, host: target.host, channel: channel, pinnedFingerprint: credentialsOut.pinnedCertificateSHA256)
        await session.start()

        let mac = ((networkInfo?["wifiInfo"] as? [String: Any])?["macAddress"] as? String)
            ?? ((networkInfo?["wiredInfo"] as? [String: Any])?["macAddress"] as? String)
            ?? (softwareInfo?["device_id"] as? String)
        let update = DeviceInfoUpdate(
            reportedName: nil,
            manufacturer: "LG",
            modelName: (systemInfo?["modelName"] as? String) ?? (softwareInfo?["model_name"] as? String),
            osVersion: (helloPayload?["deviceOSVersion"] as? String).map { "webOS \($0)" } ?? (softwareInfo?["product_name"] as? String),
            macAddress: mac,
            powerIsOn: true
        )
        return ConnectResult(session: session, credentials: credentialsOut, deviceInfo: update)
    }

    private func register(channel: LGMessageChannel, clientKey: String?, interaction: PairingInteraction) async throws -> String {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": LGManifest.unsigned,
        ]
        if let clientKey { payload["client-key"] = clientKey }

        let stream = await channel.registrationUpdates()
        try await channel.send(["type": "register", "id": "register_0", "payload": payload])

        let promptTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(clientKey == nil ? 300 : 2500))
            interaction.showConfirmOnTV()
        }
        defer { promptTask.cancel() }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await message in stream {
                    let type = message["type"] as? String
                    let payload = message["payload"] as? [String: Any]
                    switch type {
                    case "registered":
                        if let key = payload?["client-key"] as? String { return key }
                        if let clientKey { return clientKey }
                        throw AppError.pairingRejected
                    case "error":
                        let text = (message["error"] as? String) ?? ""
                        throw text.contains("cancel") || text.contains("reject") ? AppError.pairingRejected : AppError.pairingRejected
                    default:
                        continue // "response" with pairingType PROMPT: waiting for the user on the TV
                    }
                }
                throw AppError.connectionLost
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw AppError.pairingTimedOut
            }
            defer { group.cancelAll() }
            guard let key = try await group.next() else { throw AppError.pairingTimedOut }
            return key
        }
    }
}

enum LGManifest {
    /// Unsigned permission manifest (aiowebostv ≥ 0.10.0). The widely copied signed
    /// "com.lge.test" manifest is rejected by webOS 26 firmware (43.00.92+).
    static let permissions = [
        "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV",
        "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN", "LAUNCH", "LAUNCH_WEBAPP",
        "READ_APP_STATUS", "READ_COUNTRY_INFO", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
        "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE",
        "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS", "READ_SETTINGS", "READ_TV_CHANNEL_LIST",
        "READ_TV_CURRENT_TIME", "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE",
        "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
    ]

    static var unsigned: [String: Any] {
        ["manifestVersion": 1, "appVersion": "1.1", "permissions": permissions]
    }
}

/// Request/response multiplexing over one SSAP WebSocket.
actor LGMessageChannel {
    private let client: WebSocketClient
    private var nextID = 1
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var subscriptions: [String: AsyncStream<[String: Any]>.Continuation] = [:]
    private var registrationContinuation: AsyncStream<[String: Any]>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var closeHandler: (@Sendable () -> Void)?
    private(set) var isClosed = false

    init(client: WebSocketClient) {
        self.client = client
    }

    func start() {
        client.onClose { [weak self] _ in
            Task { await self?.handleClosed() }
        }
        readerTask = Task { [client, weak self] in
            for await message in client.messages {
                guard case .text(let text) = message,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { continue }
                await self?.route(json)
            }
        }
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        closeHandler = handler
    }

    func registrationUpdates() -> AsyncStream<[String: Any]> {
        let channel = EventChannel<[String: Any]>(buffer: 8)
        registrationContinuation = channel.continuation
        return channel.stream
    }

    func send(_ object: [String: Any]) async throws {
        guard !isClosed else { throw AppError.connectionLost }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await client.send(String(decoding: data, as: UTF8.self))
    }

    func call(type: String = "request", uri: String?, payload: [String: Any], timeout: Duration = .seconds(5)) async throws -> [String: Any] {
        let id = "\(type)_\(nextID)"
        nextID += 1
        var message: [String: Any] = ["id": id, "type": type, "payload": payload]
        if let uri { message["uri"] = uri }
        guard !isClosed else { throw AppError.connectionLost }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        // Register before sending: the reply can arrive while `send` is still suspended.
        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self, client] in
                do {
                    try await client.send(text)
                } catch {
                    await self?.fail(id: id, error: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeout(id: id)
            }
        }
        if (response["type"] as? String) == "error" {
            let text = (response["error"] as? String) ?? ""
            throw text.hasPrefix("401") ? AppError.commandNotSupported : AppError.commandTimedOut
        }
        if let payload = response["payload"] as? [String: Any], (payload["returnValue"] as? Bool) == false {
            throw AppError.commandNotSupported
        }
        return response
    }

    func subscribe(uri: String, payload: [String: Any] = [:]) async throws -> AsyncStream<[String: Any]> {
        let id = "sub_\(nextID)"
        nextID += 1
        let channel = EventChannel<[String: Any]>(buffer: 16)
        subscriptions[id] = channel.continuation
        try await send(["id": id, "type": "subscribe", "uri": uri, "payload": payload])
        return channel.stream
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        client.close()
        failAll()
    }

    private func timeout(id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: AppError.commandTimedOut)
    }

    private func fail(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: AppError.wrap(error))
    }

    private func route(_ json: [String: Any]) {
        let type = json["type"] as? String
        let id = json["id"] as? String
        if id == "register_0" || type == "registered" {
            registrationContinuation?.yield(json)
            if type == "registered" || type == "error" { registrationContinuation?.finish() }
            return
        }
        if let id, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: json)
            return
        }
        if let id, let subscription = subscriptions[id] {
            if let payload = json["payload"] as? [String: Any] { subscription.yield(payload) }
        }
    }

    private func failAll() {
        let waiters = pending.values
        pending.removeAll()
        waiters.forEach { $0.resume(throwing: AppError.connectionLost) }
        subscriptions.values.forEach { $0.finish() }
        subscriptions.removeAll()
        registrationContinuation?.finish()
    }

    private func handleClosed() {
        guard !isClosed else { return }
        isClosed = true
        failAll()
        closeHandler?()
    }
}

actor LGSession: TVSession {
    nonisolated let deviceID: TVDeviceID
    nonisolated let platform: TVPlatform = .lgWebOS
    nonisolated let events: AsyncStream<TVSessionEvent>
    nonisolated let supportedCommands: Set<RemoteCommand> = Set(LGKeys.pointerButtons.keys).union([.powerOff, .playPause])
    nonisolated let textInputMode: TextInputMode? = .appendAndDelete
    nonisolated let canListInstalledApps = true
    nonisolated let canOpenBrowser = true

    private let host: String
    private let channel: LGMessageChannel
    private let pinnedFingerprint: String?
    private let eventContinuation: AsyncStream<TVSessionEvent>.Continuation
    private var pointer: WebSocketClient?
    private var backgroundTasks: [Task<Void, Never>] = []
    private var foregroundAppID: String?
    private var isPlaying = false
    private var closed = false

    init(deviceID: TVDeviceID, host: String, channel: LGMessageChannel, pinnedFingerprint: String?) {
        self.deviceID = deviceID
        self.host = host
        self.channel = channel
        self.pinnedFingerprint = pinnedFingerprint
        let events = EventChannel<TVSessionEvent>()
        self.events = events.stream
        eventContinuation = events.continuation
    }

    func start() async {
        await channel.onClose { [weak self] in
            Task { await self?.handleClosed() }
        }
        await openPointerSocket()
        if let keyboard = try? await channel.subscribe(uri: "ssap://com.webos.service.ime/registerRemoteKeyboard") {
            backgroundTasks.append(Task { [weak self] in
                for await payload in keyboard {
                    let widget = payload["currentWidget"] as? [String: Any]
                    let focused = (widget?["focus"] as? Bool) ?? false
                    await self?.emit(.textField(focused ? .focused : .notFocused))
                }
            })
        }
        if let foreground = try? await channel.subscribe(uri: "ssap://com.webos.applicationManager/getForegroundAppInfo") {
            backgroundTasks.append(Task { [weak self] in
                for await payload in foreground {
                    await self?.setForeground(payload["appId"] as? String)
                }
            })
        }
    }

    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool { false }

    func send(_ command: RemoteCommand, action: KeyAction) async throws {
        guard action != .release else { return }
        switch command {
        case .powerOff, .powerToggle:
            _ = try await channel.call(uri: "ssap://system/turnOff", payload: [:])
            return
        case .playPause:
            let uri = isPlaying ? "ssap://media.controls/pause" : "ssap://media.controls/play"
            _ = try await channel.call(uri: uri, payload: [:])
            isPlaying.toggle()
            return
        default:
            break
        }
        guard let button = LGKeys.pointerButtons[command] else { throw AppError.commandNotSupported }
        if pointer == nil { await openPointerSocket() }
        if let pointer {
            try await pointer.send("type:button\nname:\(button)\n\n")
        } else if let uri = LGKeys.ssapFallback[command] {
            _ = try await channel.call(uri: uri, payload: [:])
        } else {
            throw AppError.commandNotSupported
        }
    }

    func performText(_ operation: TextInputOperation) async throws {
        switch operation {
        case .append(let text):
            _ = try await channel.call(uri: "ssap://com.webos.service.ime/insertText", payload: ["text": text, "replace": false])
        case .replaceAll(let text):
            _ = try await channel.call(uri: "ssap://com.webos.service.ime/insertText", payload: ["text": text, "replace": true])
        case .deleteBackward(let count):
            _ = try await channel.call(uri: "ssap://com.webos.service.ime/deleteCharacters", payload: ["count": count])
        case .submit:
            _ = try await channel.call(uri: "ssap://com.webos.service.ime/sendEnterKey", payload: [:])
        }
    }

    func installedApps() async throws -> [TVAppInfo] {
        let response = try await channel.call(uri: "ssap://com.webos.applicationManager/listLaunchPoints", payload: [:])
        let points = ((response["payload"] as? [String: Any])?["launchPoints"] as? [[String: Any]]) ?? []
        return points.compactMap { point in
            guard let id = point["id"] as? String, let title = point["title"] as? String else { return nil }
            return TVAppInfo(id: id, title: title, iconURL: (point["icon"] as? String).flatMap(URL.init(string:)))
        }
    }

    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome {
        var lastError: Error = AppError.appNotInstalled
        for id in app.lgIDs {
            do { return try await launch(appID: id) } catch { lastError = error }
        }
        throw lastError
    }

    func launch(appID: String) async throws -> AppLaunchOutcome {
        do {
            _ = try await channel.call(uri: "ssap://system.launcher/launch", payload: ["id": appID])
        } catch AppError.commandNotSupported {
            throw AppError.appNotInstalled
        }
        for _ in 0..<5 {
            if foregroundAppID == appID { return .confirmedForeground }
            if let response = try? await channel.call(uri: "ssap://com.webos.applicationManager/getForegroundAppInfo", payload: [:], timeout: .seconds(2)),
               ((response["payload"] as? [String: Any])?["appId"] as? String) == appID {
                return .confirmedForeground
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        return .accepted
    }

    /// Launch-point icons are served by the TV itself; only the TV's own host is accepted.
    func appIconData(for app: TVAppInfo) async -> Data? {
        guard let url = app.iconURL, url.host == host, url.scheme == "http" || url.scheme == "https" else { return nil }
        guard let response = try? await LANHTTPClient(timeout: 4).request(url), (200..<300).contains(response.status),
              response.body.count < 2_000_000
        else { return nil }
        return response.body
    }

    func openBrowser(url: URL) async throws {
        do {
            _ = try await channel.call(uri: "ssap://system.launcher/open", payload: ["target": url.absoluteString])
        } catch {
            throw AppError.mirroringBrowserLaunchFailed
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        backgroundTasks.forEach { $0.cancel() }
        pointer?.close()
        await channel.close()
        eventContinuation.finish()
    }

    // MARK: Private

    private func emit(_ event: TVSessionEvent) {
        eventContinuation.yield(event)
    }

    private func setForeground(_ appID: String?) {
        foregroundAppID = appID
        eventContinuation.yield(.foregroundApp(appID))
    }

    private func openPointerSocket() async {
        guard let response = try? await channel.call(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket", payload: [:]),
              let path = (response["payload"] as? [String: Any])?["socketPath"] as? String,
              let url = URL(string: path), url.host == host
        else { return }
        let secure = url.scheme == "wss"
        let socket = WebSocketClient(url: url, pinnedFingerprint: secure ? pinnedFingerprint : nil, allowFirstUse: secure && pinnedFingerprint == nil)
        do {
            try await socket.connect(timeout: 5)
            socket.onClose { [weak self] _ in
                Task { await self?.pointerClosed() }
            }
            pointer = socket
        } catch {
            pointer = nil
        }
    }

    private func pointerClosed() {
        pointer = nil
    }

    private func handleClosed() {
        guard !closed else { return }
        closed = true
        backgroundTasks.forEach { $0.cancel() }
        pointer?.close()
        eventContinuation.yield(.disconnected(.connectionLost))
        eventContinuation.finish()
    }
}

enum LGKeys {
    static let pointerButtons: [RemoteCommand: String] = {
        var map: [RemoteCommand: String] = [
            .up: "UP", .down: "DOWN", .left: "LEFT", .right: "RIGHT", .ok: "ENTER",
            .back: "BACK", .home: "HOME", .menu: "MENU", .settings: "QMENU", .info: "INFO", .guide: "GUIDE",
            .input: "INPUT_HUB", .volumeUp: "VOLUMEUP", .volumeDown: "VOLUMEDOWN", .mute: "MUTE",
            .channelUp: "CHANNELUP", .channelDown: "CHANNELDOWN", .play: "PLAY", .pause: "PAUSE",
            .stop: "STOP", .rewind: "REWIND", .fastForward: "FASTFORWARD",
        ]
        for (index, digit) in RemoteCommand.digits.enumerated() {
            map[digit] = "\((index + 1) % 10)"
        }
        return map
    }()

    /// SSAP URIs used when the pointer socket is unavailable.
    static let ssapFallback: [RemoteCommand: String] = [
        .volumeUp: "ssap://audio/volumeUp",
        .volumeDown: "ssap://audio/volumeDown",
        .play: "ssap://media.controls/play",
        .pause: "ssap://media.controls/pause",
        .stop: "ssap://media.controls/stop",
        .rewind: "ssap://media.controls/rewind",
        .fastForward: "ssap://media.controls/fastForward",
        .channelUp: "ssap://tv/channelUp",
        .channelDown: "ssap://tv/channelDown",
    ]
}
