import Foundation
import Observation

/// Owns the live connection to the selected TV.
///
/// Every connection gets a fresh `sessionID`; the command pipeline, event listener and
/// reconnect loop are bound to it and torn down when the user switches TVs, so responses or
/// queued commands of an old session can never affect the new one.
@MainActor
@Observable
final class ConnectionManager {
    enum State: Equatable {
        case idle
        case connecting(TVDeviceID)
        case pairing(TVDeviceID)
        case connected(TVDeviceID)
        case reconnecting(TVDeviceID, attempt: Int)
        case failed(TVDeviceID, AppError)

        var deviceID: TVDeviceID? {
            switch self {
            case .idle: nil
            case .connecting(let id), .pairing(let id), .connected(let id), .reconnecting(let id, _), .failed(let id, _): id
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle
    private(set) var sessionID = UUID()
    private(set) var session: (any TVSession)?
    private(set) var textFieldState: TVTextFieldState = .unknown
    private(set) var foregroundAppID: String?
    private(set) var powerIsOn: Bool?
    private(set) var lastCommandError: AppError?
    private(set) var connectedAt: Date?

    let pairing = PairingCoordinator()

    private let devices: DeviceStore
    private let credentials: CredentialStore
    private let analytics: AnalyticsService
    private var pipeline: CommandPipeline?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    private var commandCount = 0

    /// Called after a successful connect so capability checks can run.
    var onConnected: ((TVDevice, any TVSession) -> Void)?
    /// Why a session ended: the user moved on (switch / forget / disconnect) or the link dropped
    /// (the app reconnects on its own). Features like mirroring only stop on `.replaced`.
    enum SessionEnd { case replaced, dropped }

    /// Called when the session ends (used to stop or pause dependent features).
    var onSessionEnded: ((TVDeviceID, SessionEnd) -> Void)?
    /// Reconnect cycles since the last session that stayed up; bounds reconnect loops.
    private var reconnectCycles = 0

    init(devices: DeviceStore, credentials: CredentialStore = CredentialStore(), analytics: AnalyticsService) {
        self.devices = devices
        self.credentials = credentials
        self.analytics = analytics
    }

    static func connector(for platform: TVPlatform) -> TVConnector? {
        switch platform {
        case .samsungTizen: SamsungConnector()
        case .lgWebOS: LGConnector()
        case .androidTV: AndroidTVConnector()
        case .unknown: nil
        }
    }

    var connectedDevice: TVDevice? {
        guard case .connected(let id) = state else { return nil }
        return devices.device(id)
    }

    // MARK: Connect

    /// Connects to a TV found by discovery (first pairing or known TV at a new address).
    func connect(to discovered: DiscoveredTV) {
        let existing = devices.device(discovered.id)
        let device = TVDevice(
            id: discovered.id,
            platform: discovered.platform,
            reportedName: discovered.name,
            customName: existing?.customName,
            manufacturer: discovered.manufacturer ?? existing?.manufacturer,
            modelName: discovered.modelName ?? existing?.modelName,
            osVersion: discovered.osVersion ?? existing?.osVersion,
            host: discovered.host,
            macAddress: discovered.macAddress ?? existing?.macAddress,
            mediaRendererLocation: discovered.mediaRendererLocation ?? existing?.mediaRendererLocation,
            capabilities: existing?.capabilities ?? TVCapabilities(),
            advertisesAirPlay: discovered.advertisesAirPlay || existing?.advertisesAirPlay == true,
            addedAt: existing?.addedAt ?? .now,
            lastConnectedAt: existing?.lastConnectedAt
        )
        connect(to: device, isNew: existing == nil)
    }

    /// Connects to a saved TV.
    func connect(to device: TVDevice, isNew: Bool = false) {
        guard Self.connector(for: device.platform) != nil else {
            state = .failed(device.id, .commandNotSupported)
            return
        }
        teardownSession(notify: true, reason: .replaced)
        reconnectTask?.cancel()
        connectTask?.cancel()
        pairing.reset()
        userInitiatedDisconnect = false
        reconnectCycles = 0
        let id = UUID()
        sessionID = id
        state = .connecting(device.id)
        DiagnosticsLog.shared.record(.connectStarted, platform: device.platform)

        connectTask = Task { [weak self] in
            await self?.performConnect(device, sessionID: id, isNew: isNew)
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        reconnectTask?.cancel() // otherwise the loop flips the state back from idle
        pairing.cancel()
        if case .connected = state { return }
        state = .idle
    }

    /// "Pair again": forget the stored pairing for this TV (token, pinned certificate, Android
    /// identity) and start a fresh pairing. Only on explicit user request.
    func pairAgain(_ device: TVDevice) {
        credentials.remove(for: device.id)
        connect(to: device)
    }

    private func performConnect(_ device: TVDevice, sessionID id: UUID, isNew: Bool) async {
        guard let connector = Self.connector(for: device.platform) else { return }
        let stored = credentials.credentials(for: device.id)
        if stored == nil {
            state = .pairing(device.id)
            analytics.log(.pairingStarted(platform: device.platform))
            DiagnosticsLog.shared.record(.pairingStarted, platform: device.platform)
        }
        let target = ConnectionTarget(id: device.id, platform: device.platform, host: device.host, name: device.displayName, macAddress: device.macAddress)
        do {
            let result = try await connector.connect(target, credentials: stored, interaction: pairing)
            guard id == sessionID, !Task.isCancelled else {
                await result.session.close()
                return
            }
            pairing.reset()
            credentials.save(result.credentials, for: device.id)
            var updated = device
            let info = result.deviceInfo
            if let name = info.reportedName, !name.isEmpty { updated.reportedName = name }
            updated.manufacturer = info.manufacturer ?? updated.manufacturer
            updated.modelName = info.modelName ?? updated.modelName
            updated.osVersion = info.osVersion ?? updated.osVersion
            updated.macAddress = info.macAddress ?? updated.macAddress
            updated.lastConnectedAt = .now
            devices.upsert(updated)
            devices.select(device.id)
            attach(result.session, device: updated, sessionID: id)
            powerIsOn = info.powerIsOn
            if stored == nil {
                analytics.log(.pairingSucceeded(platform: device.platform))
                DiagnosticsLog.shared.record(.pairingSucceeded, platform: device.platform)
            }
        } catch {
            guard id == sessionID else { return }
            pairing.reset()
            if error is CancellationError || Task.isCancelled {
                state = .idle
                return
            }
            let appError = AppError.wrap(error)
            // Credentials are kept even on a certificate change: it may be a different TV at
            // this address. The error offers "Pair again", which removes them explicitly.
            state = .failed(device.id, appError)
            DiagnosticsLog.shared.record(stored == nil ? .pairingFailed : .disconnected, platform: device.platform, error: appError)
            if stored == nil { analytics.log(.pairingFailed(platform: device.platform, errorCode: appError.code)) }
        }
    }

    private func attach(_ session: any TVSession, device: TVDevice, sessionID id: UUID) {
        self.session = session
        textFieldState = .unknown
        foregroundAppID = nil
        commandCount = 0
        connectedAt = .now
        pipeline = CommandPipeline(session: session) { [weak self] command, error in
            Task { @MainActor in self?.handleCommandFailure(command, error, sessionID: id) }
        }
        state = .connected(device.id)
        DiagnosticsLog.shared.record(.connected, platform: device.platform)
        analytics.log(.remoteSessionStarted(platform: device.platform))
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.handle(event, sessionID: id)
            }
        }
        onConnected?(device, session)
    }

    // MARK: Commands

    /// Queues a command for the current session. Returns false if there is no live session.
    @discardableResult
    func send(_ command: RemoteCommand, action: KeyAction = .click) -> Bool {
        guard state.isConnected, let pipeline, let session else { return false }
        guard session.supportedCommands.contains(command) else {
            lastCommandError = .commandNotSupported
            return false
        }
        commandCount += 1
        Task { await pipeline.enqueue(command, action) }
        return true
    }

    func supportsPressRelease(_ command: RemoteCommand) -> Bool {
        session?.supportsPressRelease(command) ?? false
    }

    func clearCommandError() {
        lastCommandError = nil
    }

    private func handleCommandFailure(_ command: RemoteCommand, _ error: AppError, sessionID id: UUID) {
        guard id == sessionID else { return }
        lastCommandError = error
        DiagnosticsLog.shared.record(.commandFailed, platform: session?.platform, error: error)
    }

    // MARK: Events & lifecycle

    private func handle(_ event: TVSessionEvent, sessionID id: UUID) {
        guard id == sessionID else { return }
        switch event {
        case .textField(let state):
            textFieldState = state
        case .foregroundApp(let appID):
            foregroundAppID = appID
        case .power(let isOn):
            powerIsOn = isOn
        case .volume:
            break
        case .disconnected(let error):
            sessionEnded(error: error ?? .connectionLost, sessionID: id)
        }
    }

    private func sessionEnded(error: AppError, sessionID id: UUID) {
        guard id == sessionID, let deviceID = state.deviceID else { return }
        let platform = session?.platform
        let lasted = connectedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        if lasted > 60 { reconnectCycles = 0 } // it was a real, stable session
        logSessionEnd()
        teardownSession(notify: true, reason: .dropped)
        DiagnosticsLog.shared.record(.disconnected, platform: platform, error: error)
        guard !userInitiatedDisconnect, let device = devices.device(deviceID) else {
            state = .idle
            return
        }
        scheduleReconnect(device)
    }

    /// Bounded reconnect with backoff; re-discovers the TV if its address changed. Reconnects are
    /// silent: they never show pairing prompts (a TV that needs pairing ends in "Pair again").
    private func scheduleReconnect(_ device: TVDevice) {
        reconnectTask?.cancel()
        pairing.reset()
        reconnectCycles += 1
        guard reconnectCycles <= 3 else {
            // The TV keeps accepting and dropping the connection: stop instead of looping.
            DiagnosticsLog.shared.record(.reconnectGaveUp, platform: device.platform)
            state = .failed(device.id, .deviceUnreachable)
            return
        }
        let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
        reconnectTask = Task { [weak self] in
            var lastError: AppError = .deviceUnreachable
            for (index, delay) in delays.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.state = .reconnecting(device.id, attempt: index + 1)
                DiagnosticsLog.shared.record(.reconnectAttempt, platform: device.platform)
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                var target = self.devices.device(device.id) ?? device
                if let moved = await Self.relocate(target), moved.host != target.host {
                    self.devices.updateRoute(for: target.id, host: moved.host, mediaRendererLocation: moved.mediaRendererLocation)
                    target.host = moved.host
                }
                guard let connector = Self.connector(for: target.platform),
                      let stored = self.credentials.credentials(for: target.id)
                else { break }
                let connectTarget = ConnectionTarget(id: target.id, platform: target.platform, host: target.host, name: target.displayName, macAddress: target.macAddress)
                let id = UUID()
                self.sessionID = id
                do {
                    let result = try await connector.connect(connectTarget, credentials: stored, interaction: SilentPairingInteraction())
                    guard id == self.sessionID, !Task.isCancelled else { await result.session.close(); return }
                    self.credentials.save(result.credentials, for: target.id)
                    self.attach(result.session, device: target, sessionID: id)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = AppError.wrap(error)
                    // Authentication problems won't fix themselves by retrying: show them.
                    if [.pairingRejected, .pairingTokenRevoked, .tlsIdentityMismatch].contains(lastError) { break }
                    lastError = .deviceUnreachable
                }
            }
            guard let self, !Task.isCancelled else { return }
            DiagnosticsLog.shared.record(.reconnectGaveUp, platform: device.platform)
            self.state = .failed(device.id, lastError)
        }
    }

    /// Looks for a known TV at a new address (DHCP change) using its stable identity.
    private static func relocate(_ device: TVDevice) async -> DiscoveredTV? {
        switch device.platform {
        case .samsungTizen:
            if let here = await TVProber.probeSamsung(host: device.host), here.id == device.id { return here }
        case .lgWebOS:
            if let here = await TVProber.probeLG(host: device.host), here.id == device.id { return here }
        default:
            break
        }
        guard let network = LocalNetworkInfo.current() else { return nil }
        // Targeted scan: stop at the first host whose identity matches.
        return await withTaskGroup(of: DiscoveredTV?.self) { group -> DiscoveredTV? in
            var iterator = network.scanCandidates().makeIterator()
            for _ in 0..<24 {
                guard let host = iterator.next() else { break }
                group.addTask { await Self.probe(host: host, platform: device.platform) }
            }
            while let result = await group.next() {
                if let result, result.id == device.id { group.cancelAll(); return result }
                if let host = iterator.next() { group.addTask { await Self.probe(host: host, platform: device.platform) } }
            }
            return nil
        }
    }

    private static func probe(host: String, platform: TVPlatform) async -> DiscoveredTV? {
        switch platform {
        case .samsungTizen: await TVProber.probeSamsung(host: host)
        case .lgWebOS: await TVProber.probeLG(host: host)
        default: nil
        }
    }

    /// App returned to foreground: reconnect the selected TV if the session dropped.
    func resumeIfNeeded() {
        switch state {
        case .connected, .connecting, .pairing, .reconnecting:
            return
        default:
            guard !userInitiatedDisconnect, let device = devices.selectedDevice,
                  credentials.credentials(for: device.id) != nil
            else { return }
            connect(to: device)
        }
    }

    /// App went to background: keep the session (mirroring may need it) but stop nothing else here.
    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        connectTask?.cancel()
        pairing.reset()
        logSessionEnd()
        teardownSession(notify: true, reason: .replaced)
        state = .idle
    }

    private func logSessionEnd() {
        guard let session, let connectedAt else { return }
        analytics.log(.remoteSessionEnded(platform: session.platform, commandCount: commandCount, durationSeconds: Int(Date.now.timeIntervalSince(connectedAt))))
    }

    private func teardownSession(notify: Bool, reason: SessionEnd = .replaced) {
        let old = session
        let oldPipeline = pipeline
        let oldDeviceID = state.deviceID
        session = nil
        pipeline = nil
        connectedAt = nil
        eventTask?.cancel()
        eventTask = nil
        textFieldState = .unknown
        foregroundAppID = nil
        Task {
            await oldPipeline?.cancel()
            await old?.close()
        }
        if notify, old != nil, let oldDeviceID { onSessionEnded?(oldDeviceID, reason) }
    }

    #if DEBUG
    /// DEBUG-only hook for the simulated TV used in UI tests and visual QA.
    func attachForDebug(_ session: any TVSession, device: TVDevice) {
        teardownSession(notify: false)
        let id = UUID()
        sessionID = id
        attach(session, device: device, sessionID: id)
    }
    #endif

    /// Forget: disconnects if needed and removes local data + credentials.
    /// (A reconnect for this TV that is still pending is cancelled by `disconnect`.)
    func forget(_ id: TVDeviceID) {
        if state.deviceID == id { disconnect() }
        devices.forget(id)
    }
}
