import Foundation

/// Android TV / Google TV Remote Service v2 (the protocol used by Google's own TV remote).
/// Pairing: TCP 6467 + PIN shown on TV. Remote: TCP 6466, mutual TLS, varint-framed protobuf.
/// Sources: androidtvremote2 (Apache-2.0) protocol definitions; implemented natively here.
struct AndroidTVConnector: TVConnector {
    let platform: TVPlatform = .androidTV
    let clientName = "TV Remote (iPhone)"

    func connect(_ target: ConnectionTarget, credentials: TVCredentials?, interaction: PairingInteraction) async throws -> ConnectResult {
        var credentialsOut = credentials ?? TVCredentials()

        // Reuse the stored identity if it still exists and the TV still accepts it.
        if let label = credentials?.clientIdentityLabel,
           let identity = ClientIdentityStore.loadIdentity(label: label),
           let pinned = credentials?.pinnedCertificateSHA256 {
            do {
                let channel = try await AndroidTVRemoteChannel.open(host: target.host, identity: identity, pinnedFingerprint: pinned)
                return try await makeResult(target: target, channel: channel, credentials: credentialsOut)
            } catch let error as AppError where error == .pairingTokenRevoked {
                // Only an explicit TLS rejection of our certificate (TV reset / pairing removed on
                // the TV) discards the identity; then pair again below.
                ClientIdentityStore.removeIdentity(label: label)
            } catch {
                // Cancellation, timeouts, a dropped socket or a changed TV certificate keep the
                // pairing: a temporary failure must never start a new PIN pairing.
                throw error
            }
        }

        let identity: ClientIdentityStore.Identity
        do {
            identity = try ClientIdentityStore.makeIdentity()
        } catch {
            throw AppError.unexpected
        }
        let pairing = AndroidTVPairingSession(host: target.host, identity: identity, clientName: clientName)
        let fingerprint: String
        do {
            fingerprint = try await pairing.run(interaction: interaction)
        } catch {
            ClientIdentityStore.removeIdentity(label: identity.label)
            throw error
        }
        credentialsOut.clientIdentityLabel = identity.label
        credentialsOut.pinnedCertificateSHA256 = fingerprint
        credentialsOut.portHint = AndroidTVRemoteChannel.port

        let channel = try await AndroidTVRemoteChannel.open(host: target.host, identity: identity, pinnedFingerprint: fingerprint)
        return try await makeResult(target: target, channel: channel, credentials: credentialsOut)
    }

    private func makeResult(target: ConnectionTarget, channel: AndroidTVRemoteChannel, credentials: TVCredentials) async throws -> ConnectResult {
        let handshake: AndroidTVRemoteChannel.Handshake
        do {
            handshake = try await channel.awaitHandshake()
        } catch {
            await channel.close() // don't leak the TLS connection
            throw error
        }
        let session = AndroidTVSession(deviceID: target.id, channel: channel, activeFeatures: handshake.activeFeatures)
        await session.start()
        let update = DeviceInfoUpdate(
            reportedName: nil,
            manufacturer: handshake.vendor,
            modelName: handshake.model,
            osVersion: handshake.appVersion.map { "Android TV Remote Service \($0)" },
            macAddress: nil,
            powerIsOn: handshake.powerIsOn
        )
        return ConnectResult(session: session, credentials: credentials, deviceInfo: update)
    }
}

enum AndroidTVFeature {
    static let ping = 1
    static let key = 2
    static let ime = 4
    static let power = 32
    static let volume = 64
    static let appLink = 512
    static let requested = ping | key | ime | power | volume | appLink // 615
}

enum AndroidTVRemoteField {
    static let configure = 1
    static let setActive = 2
    static let error = 3
    static let pingRequest = 8
    static let pingResponse = 9
    static let keyInject = 10
    static let imeKeyInject = 20
    static let imeBatchEdit = 21
    static let imeShowRequest = 22
    static let start = 40
    static let setVolumeLevel = 50
    static let appLinkLaunch = 90
}

/// Owns the 6466 connection: framing, handshake replies, pings and event decoding.
actor AndroidTVRemoteChannel {
    static let port: UInt16 = 6466

    struct Handshake: Sendable {
        var activeFeatures: Int
        var model: String?
        var vendor: String?
        var appVersion: String?
        var powerIsOn: Bool?
    }

    enum Incoming: Sendable {
        case power(Bool)
        case foregroundApp(String)
        case imeCounters(ime: Int, field: Int)
        case textFieldShown
        case volume(level: Int, max: Int, muted: Bool)
        case closed
    }

    private let connection: TLSStreamConnection
    private var buffer = Protobuf.FrameBuffer()
    private var handshake = Handshake(activeFeatures: 0)
    private var handshakeDone = false
    private var handshakeWaiters: [CheckedContinuation<Handshake, Error>] = []
    private let incomingChannel = EventChannel<Incoming>(buffer: 64)
    private var readerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var closed = false

    nonisolated var incoming: AsyncStream<Incoming> { incomingChannel.stream }

    private init(connection: TLSStreamConnection) {
        self.connection = connection
    }

    static func open(host: String, identity: ClientIdentityStore.Identity, pinnedFingerprint: String) async throws -> AndroidTVRemoteChannel {
        let connection = TLSStreamConnection(host: host, port: port, identity: identity.identity, pinnedFingerprint: pinnedFingerprint, allowFirstUse: false)
        try await connection.start()
        let channel = AndroidTVRemoteChannel(connection: connection)
        await channel.startReading()
        return channel
    }

    func awaitHandshake(timeout: Duration = .seconds(8)) async throws -> Handshake {
        if handshakeDone { return handshake }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failHandshake(AppError.deviceUnreachable)
        }
        return try await withCheckedThrowingContinuation { handshakeWaiters.append($0) }
    }

    func send(_ message: Data) async throws {
        guard !closed else { throw AppError.connectionLost }
        try await connection.send(Protobuf.frame(message))
    }

    func close() {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        watchdogTask?.cancel()
        connection.cancel()
        failHandshake(AppError.connectionLost)
        incomingChannel.continuation.yield(.closed)
        incomingChannel.continuation.finish()
    }

    private func startReading() {
        readerTask = Task { [connection, weak self] in
            for await chunk in connection.incoming {
                await self?.consume(chunk)
            }
            await self?.close()
        }
        // The TV pings roughly every 5 s; silence for 16 s means the link is gone.
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                if await self.isStale() { await self.close(); return }
            }
        }
    }

    private func isStale() -> Bool {
        handshakeDone && ContinuousClock.now - lastActivity > .seconds(16)
    }

    private func failHandshake(_ error: Error) {
        guard !handshakeDone else { return }
        let waiters = handshakeWaiters
        handshakeWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func completeHandshake() {
        guard !handshakeDone else { return }
        handshakeDone = true
        let waiters = handshakeWaiters
        handshakeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: handshake) }
    }

    private func consume(_ chunk: Data) async {
        lastActivity = .now
        buffer.append(chunk)
        while true {
            let frame: Data?
            do {
                frame = try buffer.nextFrame()
            } catch {
                // Framing is broken beyond repair (e.g. an absurd length): drop the connection
                // instead of buffering forever; the app reconnects.
                close()
                return
            }
            guard let frame else { return }
            // One malformed message is skipped; framing stays intact.
            if let message = try? Protobuf.Message(frame) { await handle(message) }
        }
    }

    private func handle(_ message: Protobuf.Message) async {
        if let configure = message.message(AndroidTVRemoteField.configure) {
            let tvFeatures = configure.int(1) ?? 0
            let active = AndroidTVFeature.requested & tvFeatures
            handshake.activeFeatures = active
            if let info = configure.message(2) {
                handshake.model = info.string(1)
                handshake.vendor = info.string(2)
                handshake.appVersion = info.string(6)
            }
            let reply = Protobuf.encode { writer in
                writer.message(AndroidTVRemoteField.configure) { configure in
                    configure.varint(1, active)
                    configure.message(2) { info in
                        info.varint(3, 1)
                        info.string(4, "1")
                        info.string(5, "atvremote")
                        info.string(6, "1.0.0")
                    }
                }
            }
            try? await send(reply)
        } else if message.has(AndroidTVRemoteField.setActive) {
            let reply = Protobuf.encode { writer in
                writer.message(AndroidTVRemoteField.setActive) { $0.varint(1, handshake.activeFeatures) }
            }
            try? await send(reply)
            // Most TVs follow with remote_start; don't hang on firmware that doesn't.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.completeHandshake()
            }
        } else if let start = message.message(AndroidTVRemoteField.start) {
            let isOn = start.bool(1) ?? false
            handshake.powerIsOn = isOn
            incomingChannel.continuation.yield(.power(isOn))
            completeHandshake()
        } else if let ping = message.message(AndroidTVRemoteField.pingRequest) {
            let value = ping.int(1) ?? 0
            let reply = Protobuf.encode { writer in
                writer.message(AndroidTVRemoteField.pingResponse) { $0.varint(1, value) }
            }
            try? await send(reply)
        } else if let inject = message.message(AndroidTVRemoteField.imeKeyInject) {
            if let package = inject.message(1)?.string(12), !package.isEmpty {
                incomingChannel.continuation.yield(.foregroundApp(package))
            }
        } else if let batch = message.message(AndroidTVRemoteField.imeBatchEdit) {
            incomingChannel.continuation.yield(.imeCounters(ime: batch.int(1) ?? 0, field: batch.int(2) ?? 0))
        } else if message.has(AndroidTVRemoteField.imeShowRequest) {
            incomingChannel.continuation.yield(.textFieldShown)
        } else if let volume = message.message(AndroidTVRemoteField.setVolumeLevel) {
            incomingChannel.continuation.yield(.volume(level: volume.int(7) ?? 0, max: volume.int(6) ?? 0, muted: volume.bool(8) ?? false))
        }
    }
}

actor AndroidTVSession: TVSession {
    nonisolated let deviceID: TVDeviceID
    nonisolated let platform: TVPlatform = .androidTV
    nonisolated let events: AsyncStream<TVSessionEvent>
    nonisolated let supportedCommands: Set<RemoteCommand>
    nonisolated let textInputMode: TextInputMode?
    nonisolated let canListInstalledApps = false
    nonisolated let canOpenBrowser = false

    private let channel: AndroidTVRemoteChannel
    private let eventContinuation: AsyncStream<TVSessionEvent>.Continuation
    private var listenTask: Task<Void, Never>?
    private var imeCounter = 0
    private var fieldCounter = 0
    private var foregroundPackage: String?
    private var closed = false

    init(deviceID: TVDeviceID, channel: AndroidTVRemoteChannel, activeFeatures: Int) {
        self.deviceID = deviceID
        self.channel = channel
        var commands = Set(AndroidTVKeys.map.keys)
        if activeFeatures & AndroidTVFeature.power == 0 { commands.remove(.powerToggle) }
        if activeFeatures & AndroidTVFeature.volume == 0 { commands.subtract([.volumeUp, .volumeDown, .mute]) }
        supportedCommands = commands
        textInputMode = activeFeatures & AndroidTVFeature.ime != 0 ? .replaceField : nil
        let events = EventChannel<TVSessionEvent>()
        self.events = events.stream
        eventContinuation = events.continuation
    }

    func start() {
        listenTask = Task { [channel, weak self] in
            for await item in channel.incoming {
                await self?.handle(item)
            }
        }
    }

    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool {
        command.isRepeatable
    }

    func send(_ command: RemoteCommand, action: KeyAction) async throws {
        guard let keyCode = AndroidTVKeys.map[command] else { throw AppError.commandNotSupported }
        try await sendKey(keyCode, action: action)
    }

    func performText(_ operation: TextInputOperation) async throws {
        switch operation {
        case .replaceAll(let text):
            let cursor = max(text.utf16.count - 1, 0)
            let message = Protobuf.encode { writer in
                writer.message(AndroidTVRemoteField.imeBatchEdit) { batch in
                    batch.varint(1, imeCounter)
                    batch.varint(2, fieldCounter)
                    batch.message(3) { edit in
                        edit.varint(1, 1)
                        edit.message(2) { object in
                            object.varint(1, cursor)
                            object.varint(2, cursor)
                            object.string(3, text)
                        }
                    }
                }
            }
            try await channel.send(message)
        case .append:
            throw AppError.textNotSupported
        case .deleteBackward(let count):
            for _ in 0..<max(count, 1) { try await sendKey(67, action: .click) }
        case .submit:
            try await sendKey(66, action: .click)
        }
    }

    func installedApps() async throws -> [TVAppInfo] {
        throw AppError.appListUnavailable
    }

    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome {
        guard let link = app.androidLinks.first else { throw AppError.appNotInstalled }
        try await sendAppLink(link)
        return await confirmForeground(packages: app.androidPackages)
    }

    func launch(appID: String) async throws -> AppLaunchOutcome {
        let link = appID.contains(":") ? appID : "market://launch?id=\(appID)"
        try await sendAppLink(link)
        return await confirmForeground(packages: [appID])
    }

    func openBrowser(url: URL) async throws {
        throw AppError.mirroringReceiverMissing
    }

    /// The Android TV Remote protocol has no icon API.
    func appIconData(for app: TVAppInfo) async -> Data? { nil }

    func close() async {
        guard !closed else { return }
        closed = true
        listenTask?.cancel()
        await channel.close()
        eventContinuation.finish()
    }

    // MARK: Private

    private func sendKey(_ code: Int, action: KeyAction) async throws {
        let direction: Int
        switch action {
        case .click: direction = 3
        case .press: direction = 1
        case .release: direction = 2
        }
        let message = Protobuf.encode { writer in
            writer.message(AndroidTVRemoteField.keyInject) { key in
                key.varint(1, code)
                key.varint(2, direction)
            }
        }
        try await channel.send(message)
    }

    private func sendAppLink(_ link: String) async throws {
        let message = Protobuf.encode { writer in
            writer.message(AndroidTVRemoteField.appLinkLaunch) { $0.string(1, link) }
        }
        try await channel.send(message)
    }

    private func confirmForeground(packages: [String]) async -> AppLaunchOutcome {
        for _ in 0..<8 {
            if let foregroundPackage, packages.contains(foregroundPackage) { return .confirmedForeground }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .accepted
    }

    private func handle(_ item: AndroidTVRemoteChannel.Incoming) {
        switch item {
        case .power(let isOn):
            eventContinuation.yield(.power(isOn: isOn))
        case .foregroundApp(let package):
            foregroundPackage = package
            eventContinuation.yield(.foregroundApp(package))
        case .imeCounters(let ime, let field):
            imeCounter = ime
            fieldCounter = field
            eventContinuation.yield(.textField(.focused))
        case .textFieldShown:
            eventContinuation.yield(.textField(.focused))
        case .volume(let level, let max, let muted):
            eventContinuation.yield(.volume(level: level, max: max, muted: muted))
        case .closed:
            guard !closed else { return }
            closed = true
            eventContinuation.yield(.disconnected(.connectionLost))
            eventContinuation.finish()
        }
    }
}

enum AndroidTVKeys {
    /// Android `KeyEvent` codes.
    static let map: [RemoteCommand: Int] = {
        var map: [RemoteCommand: Int] = [
            .up: 19, .down: 20, .left: 21, .right: 22, .ok: 23,
            .back: 4, .home: 3, .menu: 82, .settings: 176, .info: 165, .guide: 172, .input: 178,
            .volumeUp: 24, .volumeDown: 25, .mute: 164, .channelUp: 166, .channelDown: 167,
            .playPause: 85, .play: 126, .pause: 127, .stop: 86, .rewind: 89, .fastForward: 90,
            .next: 87, .previous: 88, .powerToggle: 26,
        ]
        for (index, digit) in RemoteCommand.digits.enumerated() {
            map[digit] = 7 + (index + 1) % 10 // KEYCODE_0 = 7
        }
        return map
    }()
}
