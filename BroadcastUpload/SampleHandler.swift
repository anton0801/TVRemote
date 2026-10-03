import CoreMedia
import Foundation
import ImageIO
import ReplayKit

/// Broadcast Upload Extension: captures the screen (after the user confirmed the system
/// broadcast prompt) and streams it to the receiver page on the selected TV.
///
/// Nothing is recorded to disk and nothing leaves the local network. The session only runs
/// when the app prepared a fresh `MirroringRequest`; a broadcast started elsewhere stops
/// immediately with an explanation.
///
/// Note: Apple marks ReplayKit broadcast APIs deprecated in iOS 27 (replacement:
/// ScreenCaptureKit `SCContentSharingPicker`, iOS 27+). This path targets iOS 17–26 and must be
/// re-verified on iOS 27 devices (see COMPATIBILITY.md).
final class SampleHandler: RPBroadcastSampleHandler {
    private let stateQueue = DispatchQueue(label: "broadcast.state")
    private var heartbeat: DispatchSourceTimer?
    private var request: MirroringRequest?
    private var httpServer: LocalHTTPServer?
    private var frameServer: FrameStreamServer?
    private let encoder = FrameEncoder()
    private var status = MirroringStatus.idle
    private var lastFrameTime: CFTimeInterval = 0
    private var finished = false
    private var connectTimeout: DispatchWorkItem?
    private var diagnosticTimer: DispatchWorkItem?
    private var quality: Double = 0.6
    private var maxLongSide = 1280
    private var profile = MirroringQuality.auto
    private var observer: DarwinObserver?
    private var qualityObserver: DarwinObserver?
    /// Snapshot read by the capture thread (guarded by `captureLock`).
    private let captureLock = NSLock()
    private var captureServer: FrameStreamServer?
    private var captureFPS = 20
    private var captureEnabled = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let request = MirroringRequest.load(), request.isFresh else {
            publish(.stopped, reason: .noRequest)
            finish(message: ExtensionStrings.noRequest(language: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"))
            return
        }
        self.request = request
        if let quality = request.quality {
            apply(quality)
        } else {
            maxLongSide = request.maxLongSide
            captureLock.withLock { captureFPS = request.maxFramesPerSecond }
        }
        status = MirroringStatus(sessionID: request.sessionID, phase: .starting, httpPort: nil, pagePath: nil, firstFrameAt: nil,
                                 framesAcknowledged: 0, roundTripMs: nil, frameWidth: nil, frameHeight: nil, stopReason: nil, updatedAt: Date())
        status.publish()
        startHeartbeat()

        observer = DarwinObserver(name: MirroringShared.stopRequestedNotification) { [weak self] in
            self?.stop(reason: .userStopped)
        }
        qualityObserver = DarwinObserver(name: MirroringShared.qualityChangedNotification) { [weak self] in
            guard let self else { return }
            let chosen = MirroringQuality.stored
            self.stateQueue.async { self.apply(chosen) }
        }

        Task { await startServers(request) }
    }

    private func startServers(_ request: MirroringRequest) async {
        do {
            let frames = FrameStreamServer(token: request.token, allowedHost: request.tvHost)
            frames.onEvent = { [weak self] event in self?.handle(event) }
            let wsPort = try await frames.start()
            let http = LocalHTTPServer()
            http.allowedClientHost = request.tvHost
            let httpPort = try await http.start()
            let page = ReceiverPage.html(webSocketPort: wsPort, token: request.token, language: request.languageCode)
            let path = http.register(.init(body: .data(Data(page.utf8)), contentType: "text/html; charset=utf-8",
                                           expiresAt: Date().addingTimeInterval(6 * 3600), dlnaTransferMode: nil, dlnaContentFeatures: nil),
                                     fileName: "receiver.html")
            stateQueue.sync {
                frameServer = frames
                httpServer = http
                status.httpPort = httpPort
                status.pagePath = path
            }
            captureLock.withLock { captureServer = frames }
            publish(.waitingForTV)
            // The app opens the page on the TV; give up if the TV never connects.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.status.phase == .waitingForTV || self.status.phase == .connecting else { return }
                self.stop(reason: .tvNeverConnected)
            }
            connectTimeout = timeout
            stateQueue.asyncAfter(deadline: .now() + 60, execute: timeout)
        } catch {
            stop(reason: .failed)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        let (server, enabled, fps) = captureLock.withLock { (captureServer, captureEnabled, captureFPS) }
        guard sampleBufferType == .video, enabled, let frameServer = server, frameServer.canSend,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let now = CACurrentMediaTime()
        let interval = 1.0 / Double(max(fps, 1))
        guard now - lastFrameTime >= interval else { return }
        lastFrameTime = now

        adaptToThermalState()
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        autoreleasepool {
            guard let frame = encoder.encode(pixelBuffer, maxLongSide: maxLongSide, quality: quality) else { return }
            frameServer.send(jpeg: frame.data, quarterTurns: orientation.receiverQuarterTurns)
            stateQueue.async { [weak self] in
                self?.status.frameWidth = frame.width
                self?.status.frameHeight = frame.height
            }
        }
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        // Stopped by the system (status bar / Control Center) or after finishBroadcastWithError.
        stop(reason: .systemStopped, callFinish: false)
    }

    // MARK: Events

    private func handle(_ event: FrameStreamServer.Event) {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            switch event {
            case .clientConnected:
                if self.status.phase == .waitingForTV { self.publishLocked(.connecting) }
            case .frameAcknowledged(_, let rtt):
                self.status.framesAcknowledged += 1
                self.status.roundTripMs = rtt
                self.adaptToLatency(rtt)
                if self.status.firstFrameAt == nil {
                    self.status.firstFrameAt = Date()
                    self.connectTimeout?.cancel()
                    self.publishLocked(.streaming)
                    self.scheduleDiagnosticLimit()
                } else if self.status.framesAcknowledged % 30 == 0 {
                    self.status.updatedAt = Date()
                    self.status.publish()
                }
            case .clientDisconnected:
                if self.status.phase == .streaming || self.status.phase == .connecting {
                    self.stopLocked(reason: .tvDisconnected)
                }
            }
        }
    }

    private func scheduleDiagnosticLimit() {
        guard case .diagnostic(let limit)? = request?.mode else { return }
        let work = DispatchWorkItem { [weak self] in self?.stopLocked(reason: .diagnosticLimit) }
        diagnosticTimer = work
        stateQueue.asyncAfter(deadline: .now() + .seconds(max(limit, 1)), execute: work)
    }

    /// Switches the picture profile (at start or when the user changes it while mirroring).
    private func apply(_ chosen: MirroringQuality) {
        profile = chosen
        quality = chosen.maxCompressionQuality
        maxLongSide = chosen.maxLongSide
        captureLock.withLock { captureFPS = chosen.framesPerSecond }
    }

    private func adaptToLatency(_ rtt: Int) {
        if rtt > 400 {
            quality = max(profile.minCompressionQuality, quality - 0.05)
            maxLongSide = max(profile.minLongSide, maxLongSide - 64)
        } else if rtt < 120, quality < profile.maxCompressionQuality {
            quality = min(profile.maxCompressionQuality, quality + 0.02)
        }
    }

    private func adaptToThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            quality = min(quality, 0.45)
            maxLongSide = min(maxLongSide, 960)
        case .critical:
            stop(reason: .thermal)
        default:
            break
        }
    }

    // MARK: Stop

    private func stop(reason: MirroringStatus.StopReason, callFinish: Bool = true) {
        stateQueue.async { [weak self] in self?.stopLocked(reason: reason, callFinish: callFinish) }
    }

    /// Lets the app tell "running with a static screen" from "extension gone".
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + MirroringShared.heartbeatInterval, repeating: MirroringShared.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, self.status.phase != .stopped else { return }
            self.status.updatedAt = Date()
            self.status.publish()
        }
        timer.resume()
        heartbeat = timer
    }

    private func stopLocked(reason: MirroringStatus.StopReason, callFinish: Bool = true) {
        guard !finished else { return }
        finished = true
        heartbeat?.cancel()
        heartbeat = nil
        connectTimeout?.cancel()
        diagnosticTimer?.cancel()
        let language = request?.languageCode ?? "en"
        let endMessage = reason == .diagnosticLimit ? "end:test" : "end:stop"
        let frames = frameServer
        let http = httpServer
        frameServer = nil
        httpServer = nil
        status.stopReason = reason
        publishLocked(.stopped)
        observer = nil
        qualityObserver = nil
        let shutdown = {
            frames?.stop()
            http?.stop()
        }
        if let frames {
            frames.sendText(endMessage) { shutdown() }
            stateQueue.asyncAfter(deadline: .now() + 0.5) { shutdown() }
        } else {
            shutdown()
        }
        guard callFinish else { return }
        let message: String
        switch reason {
        case .diagnosticLimit: message = ExtensionStrings.testEnded(language: language)
        case .thermal: message = ExtensionStrings.thermal(language: language)
        case .tvNeverConnected: message = ExtensionStrings.tvNeverConnected(language: language)
        case .tvDisconnected, .networkLost: message = ExtensionStrings.tvDisconnected(language: language)
        case .failed: message = ExtensionStrings.failed(language: language)
        default: message = ExtensionStrings.stopped(language: language)
        }
        finish(message: message)
    }

    private func finish(message: String) {
        let error = NSError(domain: "app.TVRemoteScreenMirroring.BroadcastUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(error)
    }

    private func publish(_ phase: MirroringStatus.Phase, reason: MirroringStatus.StopReason? = nil) {
        stateQueue.async { [weak self] in
            if let reason { self?.status.stopReason = reason }
            self?.publishLocked(phase)
        }
    }

    private func publishLocked(_ phase: MirroringStatus.Phase) {
        status.phase = phase
        captureLock.withLock {
            captureEnabled = phase == .connecting || phase == .streaming
            if phase == .stopped { captureServer = nil }
        }
        status.updatedAt = Date()
        status.publish()
    }
}

/// Messages the system shows when the extension ends the broadcast (5 languages).
enum ExtensionStrings {
    private static func pick(_ language: String, en: String, es: String, ru: String, de: String, fr: String) -> String {
        switch language {
        case "es": es
        case "ru": ru
        case "de": de
        case "fr": fr
        default: en
        }
    }

    static func noRequest(language: String) -> String {
        pick(language,
             en: "Open TV Remote, choose your TV and start Screen Mirroring there.",
             es: "Abre TV Remote, elige tu TV e inicia allí la duplicación de pantalla.",
             ru: "Откройте TV Remote, выберите телевизор и начните трансляцию экрана в приложении.",
             de: "Öffne TV Remote, wähle deinen Fernseher und starte dort die Bildschirmspiegelung.",
             fr: "Ouvrez TV Remote, choisissez votre téléviseur et lancez la recopie de l’écran depuis l’app.")
    }

    static func stopped(language: String) -> String {
        pick(language, en: "Screen Mirroring stopped.", es: "Se detuvo la duplicación de pantalla.",
             ru: "Трансляция экрана остановлена.", de: "Bildschirmspiegelung beendet.", fr: "La recopie de l’écran est arrêtée.")
    }

    static func testEnded(language: String) -> String {
        pick(language,
             en: "The free mirroring test has ended. Continue in TV Remote.",
             es: "La prueba gratuita de duplicación ha terminado. Continúa en TV Remote.",
             ru: "Бесплатная проверка трансляции завершена. Продолжите в TV Remote.",
             de: "Der kostenlose Spiegelungstest ist beendet. Fahre in TV Remote fort.",
             fr: "Le test gratuit de recopie est terminé. Continuez dans TV Remote.")
    }

    static func thermal(language: String) -> String {
        pick(language,
             en: "Mirroring stopped because the iPhone is too warm. Let it cool down and try again.",
             es: "La duplicación se detuvo porque el iPhone está demasiado caliente. Deja que se enfríe e inténtalo de nuevo.",
             ru: "Трансляция остановлена: iPhone слишком нагрелся. Дайте ему остыть и попробуйте снова.",
             de: "Die Spiegelung wurde beendet, weil das iPhone zu warm ist. Lass es abkühlen und versuche es erneut.",
             fr: "La recopie s’est arrêtée car l’iPhone est trop chaud. Laissez-le refroidir et réessayez.")
    }

    static func tvNeverConnected(language: String) -> String {
        pick(language,
             en: "The TV did not open the mirroring page. Check the TV and try again.",
             es: "La TV no abrió la página de duplicación. Revisa la TV e inténtalo de nuevo.",
             ru: "Телевизор не открыл страницу трансляции. Проверьте телевизор и попробуйте снова.",
             de: "Der Fernseher hat die Spiegelungsseite nicht geöffnet. Prüfe den Fernseher und versuche es erneut.",
             fr: "Le téléviseur n’a pas ouvert la page de recopie. Vérifiez le téléviseur et réessayez.")
    }

    static func tvDisconnected(language: String) -> String {
        pick(language,
             en: "The connection to the TV was lost.",
             es: "Se perdió la conexión con la TV.",
             ru: "Связь с телевизором потеряна.",
             de: "Die Verbindung zum Fernseher wurde getrennt.",
             fr: "La connexion avec le téléviseur a été perdue.")
    }

    static func failed(language: String) -> String {
        pick(language,
             en: "Screen Mirroring could not start on this network.",
             es: "No se pudo iniciar la duplicación de pantalla en esta red.",
             ru: "Не удалось начать трансляцию экрана в этой сети.",
             de: "Die Bildschirmspiegelung konnte in diesem Netzwerk nicht gestartet werden.",
             fr: "Impossible de lancer la recopie de l’écran sur ce réseau.")
    }
}
