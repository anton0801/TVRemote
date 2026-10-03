import Foundation
import Observation

/// App side of our own Screen Mirroring (ReplayKit broadcast extension → TV browser page).
///
/// Flow: the setup screen *arms* a fresh request (token, TV address, free-test or unlimited
/// mode) → the user taps the system broadcast button and confirms Apple's prompt → the
/// extension starts its local servers → the app opens the receiver page in the TV browser →
/// the TV acknowledges the first displayed frame → only then the session counts as started.
@MainActor
@Observable
final class MirroringController {
    enum Phase: Equatable {
        case idle
        /// Extension running; opening the receiver page on the TV.
        case openingReceiver
        /// Page opening / TV connecting; no confirmed frame yet.
        case waitingForTV
        case streaming
        case stopping
        case ended(MirroringStatus.StopReason)
        case failed(AppError)
    }

    private(set) var phase: Phase = .idle
    private(set) var status: MirroringStatus = .idle
    private(set) var deviceID: TVDeviceID?
    private(set) var isDiagnostic = false
    /// A fresh request is written; the system picker may start the extension.
    private(set) var isArmed = false
    /// Picture profile (design 45). Kept in the App Group so the extension applies it.
    private(set) var quality: MirroringQuality = MirroringQuality.stored
    /// Called once the TV acknowledged a displayed frame (a verified successful use).
    var onVerifiedUse: (() -> Void)?

    private let connection: ConnectionManager
    private let access: AccessController
    private let paywall: PaywallPresenter
    private let checker: CompatibilityChecker
    private let analytics: AnalyticsService
    private var platform: TVPlatform?
    private var request: MirroringRequest?
    /// Free-check seconds already used on this TV before the current session. The extension
    /// reports per-session time; the stored total is `base + session` so repeated short
    /// sessions add up instead of each being compared to the previous maximum.
    private var diagnosticBaseSeconds: Double = 0
    private var observer: DarwinObserver?
    private var pollTask: Task<Void, Never>?
    private var receiverOpened = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(connection: ConnectionManager, access: AccessController, paywall: PaywallPresenter, checker: CompatibilityChecker, analytics: AnalyticsService) {
        self.connection = connection
        self.access = access
        self.paywall = paywall
        self.checker = checker
        self.analytics = analytics
        adoptRunningSessionOrClear()
    }

    /// If the app was relaunched while the extension is still streaming, re-attach to that
    /// session so it can be shown and stopped; otherwise drop any leftover request so it can
    /// never start a broadcast later.
    private func adoptRunningSessionOrClear() {
        guard let request = MirroringRequest.load(), let status = MirroringStatus.load(),
              status.sessionID == request.sessionID, status.phase != .stopped,
              Date().timeIntervalSince(status.updatedAt) < MirroringShared.heartbeatTimeout
        else {
            MirroringRequest.clear()
            return
        }
        self.request = request
        self.status = status
        if case .diagnostic = request.mode { isDiagnostic = true }
        deviceID = request.deviceID.map(TVDeviceID.init(rawValue:))
        diagnosticBaseSeconds = request.usedBeforeSeconds ?? 0
        receiverOpened = true
        phase = status.phase == .streaming ? .streaming : .waitingForTV
        startObserving()
    }

    var isActive: Bool {
        switch phase {
        case .openingReceiver, .waitingForTV, .streaming, .stopping: true
        default: false
        }
    }

    var isCapturing: Bool {
        switch phase {
        case .openingReceiver, .waitingForTV, .streaming: true
        default: false
        }
    }

    /// Remaining free test seconds (nil with Remote Pro).
    var diagnosticRemaining: Double? {
        guard isDiagnostic else { return nil }
        let limit: Double
        if case .diagnostic(let seconds)? = request?.mode { limit = Double(seconds) } else { limit = Double(access.allowance.limits.mirroringSeconds) }
        return max(0, limit - status.confirmedSeconds())
    }

    /// Checks whether own mirroring can start on the connected TV.
    func readiness() -> AppError? {
        guard let session = connection.session, connection.state.isConnected else { return .connectionLost }
        guard session.canOpenBrowser else { return .mirroringReceiverMissing }
        guard LocalNetworkInfo.current() != nil else { return .noWiFi }
        return nil
    }

    /// Access decision for the connected TV without side effects.
    func accessDecision() -> AccessController.Decision? {
        guard let device = connection.connectedDevice else { return nil }
        return access.decision(.mirroring, device: device.id)
    }

    /// Writes a fresh request so the system broadcast picker can start the extension.
    /// Nothing is captured until the user confirms Apple's system prompt.
    @discardableResult
    func arm(languageCode: String) -> Bool {
        guard !isActive else { return true }
        guard readiness() == nil, let device = connection.connectedDevice else {
            disarm()
            return false
        }
        let mode: MirroringRequest.Mode
        switch access.decision(.mirroring, device: device.id) {
        case .full:
            mode = .unlimited
            isDiagnostic = false
        case .diagnostic(let remaining):
            mode = .diagnostic(limitSeconds: Int(remaining.rounded(.down)))
            isDiagnostic = true
        case .requiresPro:
            disarm()
            return false
        }
        diagnosticBaseSeconds = access.allowance.usage(for: device.id).mirroringSeconds
        let request = MirroringRequest(
            sessionID: UUID(), token: LocalHTTPServer.makeToken(), tvHost: device.host, mode: mode,
            createdAt: Date(), languageCode: languageCode, maxLongSide: quality.maxLongSide, maxFramesPerSecond: quality.framesPerSecond, quality: quality,
            deviceID: device.id.rawValue, usedBeforeSeconds: diagnosticBaseSeconds
        )
        request.save()
        self.request = request
        deviceID = device.id
        platform = device.platform
        receiverOpened = false
        isArmed = true
        startObserving()
        DiagnosticsLog.shared.record(.mirroringSetupStarted, platform: device.platform)
        return true
    }

    /// Changes the picture profile. Applies to the running session at once (the extension is
    /// told through the App Group) and to the next start.
    func setQuality(_ value: MirroringQuality) {
        quality = value
        MirroringQuality.stored = value
        if var pending = request, !isActive {
            pending.quality = value
            pending.maxLongSide = value.maxLongSide
            pending.maxFramesPerSecond = value.framesPerSecond
            pending.save()
            request = pending
        }
        if isActive { MirroringShared.post(MirroringShared.qualityChangedNotification) }
    }

    /// Leaves the setup screen without starting: the request is withdrawn.
    func disarm() {
        guard !isActive else { return }
        isArmed = false
        teardownObservation()
        MirroringRequest.clear()
        request = nil
    }

    func requestUnlock() {
        guard let device = connection.connectedDevice else { return }
        paywall.present(.mirroring, feature: .mirroring, deviceID: device.id)
    }

    /// Stops capture, encoding, network and the receiver session. Waits (briefly) until the
    /// extension confirms, so a paywall or support form is never captured on the TV.
    func stop() async {
        guard isActive else { return }
        // A second caller (e.g. switching TVs while the paywall also stops capture) waits for
        // the same stop instead of replacing — and losing — the first caller's continuation.
        if let running = stopTask {
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.phase = .stopping
            MirroringShared.post(MirroringShared.stopRequestedNotification)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.stopContinuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.resumeStopWaiter()
                }
            }
            if self.phase == .stopping { self.phase = .ended(.userStopped) }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private var stopTask: Task<Void, Never>?

    /// Clears an ended/failed state back to setup.
    func acknowledgeEnd() {
        switch phase {
        case .ended, .failed: reset()
        default: break
        }
    }

    // MARK: Status handling

    private func startObserving() {
        observer = DarwinObserver(name: MirroringShared.statusChangedNotification) { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshStatus() {
        guard let request, var latest = MirroringStatus.load(), latest.sessionID == request.sessionID else { return }
        if latest.phase != .stopped, Date().timeIntervalSince(latest.updatedAt) > MirroringShared.heartbeatTimeout {
            // No heartbeat: the extension is gone (killed by iOS). Treat it as stopped at its
            // last sign of life, so free-check seconds aren't counted by the wall clock.
            latest.phase = .stopped
            latest.stopReason = latest.stopReason ?? .systemStopped
        }
        status = latest
        if let deviceID, isDiagnostic {
            access.allowance.setMirroringUsed(diagnosticBaseSeconds + latest.confirmedSeconds(), for: deviceID)
        }
        switch latest.phase {
        case .starting:
            isArmed = false
            if !isActive { phase = .openingReceiver }
        case .waitingForTV:
            isArmed = false
            if !isActive { phase = .openingReceiver }
            if !receiverOpened { openReceiver(latest) }
        case .connecting:
            if phase == .openingReceiver { phase = .waitingForTV }
        case .streaming:
            if phase != .streaming, phase != .stopping {
                phase = .streaming
                onVerifiedUse?()
                if let deviceID { checker.confirmMirroring(for: deviceID) }
                if let platform {
                    analytics.log(.mirroringStarted(platform: platform))
                    DiagnosticsLog.shared.record(.mirroringFirstFrame, platform: platform)
                }
            }
        case .stopped:
            guard isActive || isArmed else { return }
            finishSession(reason: latest.stopReason ?? .systemStopped, status: latest)
        }
    }

    private func openReceiver(_ status: MirroringStatus) {
        guard let port = status.httpPort, let path = status.pagePath, let network = LocalNetworkInfo.current(),
              let url = URL(string: "http://\(network.address):\(port)\(path)"), let session = connection.session
        else {
            fail(.mirroringNotStarted)
            return
        }
        receiverOpened = true
        phase = .waitingForTV
        Task {
            do {
                try await session.openBrowser(url: url)
                DiagnosticsLog.shared.record(.mirroringReceiverOpened, platform: session.platform)
            } catch {
                fail(AppError.wrap(error) == .mirroringReceiverMissing ? .mirroringReceiverMissing : .mirroringBrowserLaunchFailed)
            }
        }
    }

    private func fail(_ error: AppError) {
        MirroringShared.post(MirroringShared.stopRequestedNotification)
        phase = .failed(error)
        if let platform {
            analytics.log(.mirroringFailed(platform: platform, errorCode: error.code))
            DiagnosticsLog.shared.record(.mirroringFailed, platform: platform, error: error)
        }
        teardownObservation()
        MirroringRequest.clear()
        isArmed = false
    }

    private func finishSession(reason: MirroringStatus.StopReason, status: MirroringStatus) {
        let seconds = Int(status.confirmedSeconds())
        if let platform {
            if status.firstFrameAt != nil {
                analytics.log(.mirroringStopped(platform: platform, durationSeconds: seconds))
            }
            DiagnosticsLog.shared.record(.mirroringStopped, platform: platform)
        }
        if let deviceID, isDiagnostic {
            // Technical failure early in the free test: allow one retry.
            if reason == .tvDisconnected || reason == .networkLost || reason == .failed {
                access.allowance.refundAfterTechnicalFailure(.mirroring, usedSeconds: status.confirmedSeconds(), for: deviceID)
            }
            analytics.log(.diagnosticCompleted(feature: .mirroring, exhausted: reason == .diagnosticLimit))
        }
        switch reason {
        case .tvNeverConnected: phase = .failed(.mirroringReceiverMissing)
        case .thermal: phase = .failed(.mirroringThermal)
        case .networkLost, .tvDisconnected: phase = .failed(.mirroringNetworkLost)
        case .failed: phase = .failed(.mirroringNotStarted)
        default: phase = .ended(reason)
        }
        isArmed = false
        resumeStopWaiter()
        teardownObservation()
        MirroringRequest.clear()
        if reason == .diagnosticLimit, let deviceID {
            // Capture has already stopped, so the paywall cannot appear on the TV.
            paywall.present(.mirroring, feature: .mirroring, deviceID: deviceID)
        }
    }

    private func resumeStopWaiter() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }

    private func teardownObservation() {
        observer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func reset() {
        teardownObservation()
        MirroringRequest.clear()
        request = nil
        phase = .idle
        isArmed = false
        isDiagnostic = false
        resumeStopWaiter()
    }
}
