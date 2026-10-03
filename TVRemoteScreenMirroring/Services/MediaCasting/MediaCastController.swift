import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

/// Photos & videos on the TV via its UPnP MediaRenderer. Content stays on the local network:
/// the TV pulls the selected file from a short-lived token URL on the phone.
@MainActor
@Observable
final class MediaCastController {
    struct CastItem: Identifiable {
        enum Kind {
            case photo(Data)
            case video(URL)
        }

        let id = UUID()
        let kind: Kind
        let thumbnail: UIImage?
        /// Video length and picture height, read from the file (nil for photos / unreadable).
        var duration: TimeInterval?
        var pixelHeight: Int?

        var isVideo: Bool {
            if case .video = kind { return true }
            return false
        }
    }

    enum Phase: Equatable {
        case idle
        /// Loading the picked files (may download from iCloud).
        case loading
        case preview
        /// Sending a photo / asking the TV to start playback.
        case sending
        /// Converting video for the TV.
        case preparing(progress: Double)
        case casting
        case failed(AppError)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [CastItem] = []
    private(set) var currentIndex = 0
    private(set) var transport: MediaRendererController.TransportState?
    private(set) var slideshowRunning = false
    var fitMode: PhotoFitMode = .fit
    /// Called when the TV confirmed showing the user's media (a verified successful use).
    var onVerifiedUse: (() -> Void)?

    private let connection: ConnectionManager
    private let checker: CompatibilityChecker
    private let access: AccessController
    private let paywall: PaywallPresenter
    private let settings: AppSettings
    private let analytics: AnalyticsService
    private var server: LocalHTTPServer?
    private var renderer: MediaRendererController?
    private var rendererDeviceID: TVDeviceID?
    private var loadTask: Task<Void, Never>?
    private var castTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var preparedFiles: [URL] = []
    /// Converted video per item, so casting the same video again doesn't re-export a copy.
    private var exportedVideos: [UUID: URL] = [:]
    private var castSessionID: UUID?

    init(connection: ConnectionManager, checker: CompatibilityChecker, access: AccessController, paywall: PaywallPresenter, settings: AppSettings, analytics: AnalyticsService) {
        self.connection = connection
        self.checker = checker
        self.access = access
        self.paywall = paywall
        self.settings = settings
        self.analytics = analytics
    }

    var currentItem: CastItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var isCasting: Bool { phase == .casting }

    /// Anything in flight for the TV (sending, converting or playing): switching TVs must stop it.
    var isBusy: Bool {
        switch phase {
        case .sending, .preparing, .casting: true
        default: false
        }
    }

    // MARK: Selection

    /// Loads picked files. A new selection replaces the old one unless `appending` (the
    /// "Add videos" action keeps what was chosen before).
    func load(_ pickerItems: [PhotosPickerItem], appending: Bool = false) {
        guard !pickerItems.isEmpty else { return }
        cancelLoading()
        if isBusy { stop() }
        let kept = appending ? items : []
        if !appending {
            // A new selection replaces the old one: delete its temporary files.
            preparedFiles.forEach(MediaWorkspace.remove)
            preparedFiles = []
            exportedVideos = [:]
        }
        items = kept
        currentIndex = min(currentIndex, max(kept.count - 1, 0))
        phase = .loading
        loadTask = Task {
            var loaded: [CastItem] = kept
            do {
                for item in pickerItems {
                    try Task.checkCancellation()
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw AppError.mediaLoadFailed }
                        preparedFiles.append(movie.url)
                        let info = await Self.videoInfo(movie.url)
                        loaded.append(CastItem(kind: .video(movie.url), thumbnail: await Self.videoThumbnail(movie.url),
                                               duration: info.duration, pixelHeight: info.height))
                    } else {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError.mediaLoadFailed }
                        let thumb = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 900, height: 900))
                        loaded.append(CastItem(kind: .photo(data), thumbnail: thumb))
                    }
                }
                items = loaded
                currentIndex = appending ? min(currentIndex, max(loaded.count - 1, 0)) : 0
                phase = loaded.isEmpty ? .idle : .preview
            } catch is CancellationError {
                items = kept
                phase = kept.isEmpty ? .idle : .preview
            } catch {
                // PhotosPicker surfaces iCloud download failures as load errors.
                phase = .failed(Self.isNetworkError(error) ? .mediaICloudDownloadFailed : .mediaLoadFailed)
                DiagnosticsLog.shared.record(.mediaPrepareFailed, error: .mediaLoadFailed)
            }
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: Casting

    /// Starts showing the current item. Always an explicit user action.
    func showOnTV() {
        guard let item = currentItem, let device = connection.connectedDevice else {
            phase = .failed(.connectionLost)
            return
        }
        guard mayCast(item, on: device) else { return }
        cast(item, on: device)
    }

    /// The single access gate for every cast (first item, Next/Previous, slideshow): videos need
    /// Remote Pro, photos may use the free check. Shows the paywall instead of casting.
    private func mayCast(_ item: CastItem, on device: TVDevice) -> Bool {
        if item.isVideo {
            guard access.hasPro else {
                stopSlideshow()
                paywall.present(.mirroring, feature: nil, deviceID: device.id)
                return false
            }
        } else if access.decision(.photo, device: device.id) == .requiresPro {
            stopSlideshow()
            paywall.present(.mirroring, feature: .photo, deviceID: device.id)
            return false
        }
        return true
    }

    /// Jumps to a chosen item (thumbnail strip, video list). Recasts only if already casting.
    func select(_ id: CastItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index != currentIndex else { return }
        currentIndex = index
        castCurrentIfCasting()
    }

    /// Removes one item from the selection; stops the TV first if it is the one showing.
    func remove(_ id: CastItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if index == currentIndex, isBusy { stop() }
        if case .video(let url) = items[index].kind {
            MediaWorkspace.remove(url)
            preparedFiles.removeAll { $0 == url }
            exportedVideos[items[index].id].map(MediaWorkspace.remove)
            exportedVideos[items[index].id] = nil
        }
        items.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        currentIndex = min(currentIndex, max(items.count - 1, 0))
        if items.isEmpty { phase = .idle }
    }

    func next() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + 1) % items.count
        castCurrentIfCasting()
    }

    func previous() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
        castCurrentIfCasting()
    }

    private func castCurrentIfCasting() {
        guard phase == .casting, let device = connection.connectedDevice, let item = currentItem else { return }
        guard mayCast(item, on: device) else { return }
        cast(item, on: device)
    }

    func toggleSlideshow() {
        if slideshowRunning {
            stopSlideshow()
        } else {
            guard access.hasPro, items.filter({ !$0.isVideo }).count > 1 else { return }
            slideshowRunning = true
            slideshowTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = self?.settings.slideshowInterval ?? 5
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self, self.phase == .casting else { return }
                    self.next()
                }
            }
        }
    }

    func stopSlideshow() {
        slideshowRunning = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    func playPause() {
        guard let renderer else { return }
        Task {
            if transport?.state == .playing { try? await renderer.pause() } else { try? await renderer.play() }
            await refreshTransport()
        }
    }

    func seek(by delta: TimeInterval) {
        guard let renderer, let position = transport?.position else { return }
        Task {
            try? await renderer.seek(to: max(0, position + delta))
            await refreshTransport()
        }
    }

    /// Stops playback on the TV, shuts the server and deletes temporary files.
    func stop() {
        stopSlideshow()
        castTask?.cancel()
        pollTask?.cancel()
        let renderer = self.renderer
        Task { try? await renderer?.stop() }
        server?.stop()
        server = nil
        transport = nil
        castSessionID = nil
        if phase == .casting || phase != .idle { phase = items.isEmpty ? .idle : .preview }
        DiagnosticsLog.shared.record(.mediaCastStopped)
    }

    /// Clears the selection and all temporary files.
    func clear() {
        stop()
        items = []
        preparedFiles.forEach(MediaWorkspace.remove)
        preparedFiles = []
        phase = .idle
    }

    private func cast(_ item: CastItem, on device: TVDevice) {
        castTask?.cancel()
        pollTask?.cancel()
        let sessionID = UUID()
        castSessionID = sessionID
        let platform = device.platform
        phase = item.isVideo ? .preparing(progress: 0) : .sending
        castTask = Task {
            do {
                guard let network = LocalNetworkInfo.current() else { throw AppError.noWiFi }
                let renderer = try await rendererFor(device)
                let server = self.server ?? LocalHTTPServer()
                server.allowedClientHost = device.host
                self.server = server
                let port = try await server.start()
                server.unregisterAll()

                let path: String
                let mime: String
                switch item.kind {
                case .photo(let data):
                    let jpeg = try MediaPreparation.jpegForTV(from: data, mode: fitMode)
                    mime = "image/jpeg"
                    path = server.register(.init(body: .data(jpeg), contentType: mime, expiresAt: .now.addingTimeInterval(3600),
                                                 dlnaTransferMode: "Interactive", dlnaContentFeatures: "DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_OP=01;DLNA.ORG_FLAGS=00900000000000000000000000000000"), fileName: "photo.jpg")
                case .video(let url):
                    phase = .preparing(progress: 0)
                    let ready: URL
                    if let cached = exportedVideos[item.id], FileManager.default.fileExists(atPath: cached.path) {
                        ready = cached
                    } else {
                        let info = try await MediaPreparation.inspectVideo(url)
                        ready = try await MediaPreparation.exportForTV(url, info: info) { [weak self] value in
                            if case .preparing = self?.phase { self?.phase = .preparing(progress: value) }
                        }
                        if ready != url { preparedFiles.append(ready) }
                        exportedVideos[item.id] = ready
                    }
                    mime = "video/mp4"
                    path = server.register(.init(body: .file(ready), contentType: mime, expiresAt: .now.addingTimeInterval(6 * 3600),
                                                 dlnaTransferMode: "Streaming", dlnaContentFeatures: "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"), fileName: "video.mp4")
                }
                guard castSessionID == sessionID, !Task.isCancelled else { return }
                // The user may have switched TVs while the video was converting.
                guard connection.connectedDevice?.id == device.id else { throw AppError.connectionLost }
                guard let url = URL(string: "http://\(network.address):\(port)\(path)") else { throw AppError.mediaLoadFailed }
                try await renderer.load(url: url, mimeType: mime, title: item.isVideo ? "Video" : "Photo", isImage: !item.isVideo)
                guard castSessionID == sessionID else { return }
                phase = .casting
                onVerifiedUse?()
                DiagnosticsLog.shared.record(.mediaCastStarted, platform: platform)
                analytics.log(.mediaCastStarted(platform: platform, isVideo: item.isVideo))
                if !item.isVideo, !access.hasPro {
                    access.allowance.recordPhotoShown(for: device.id)
                    analytics.log(.diagnosticCompleted(feature: .photo, exhausted: access.allowance.isExhausted(.photo, for: device.id)))
                }
                if item.isVideo { startPolling(sessionID: sessionID) }
            } catch is CancellationError {
                if castSessionID == sessionID { phase = .preview }
            } catch {
                guard castSessionID == sessionID else { return }
                let appError = AppError.wrap(error)
                phase = .failed(appError)
                DiagnosticsLog.shared.record(.mediaCastFailed, platform: platform, error: appError)
                analytics.log(.mediaCastFailed(platform: platform, errorCode: appError.code))
            }
        }
    }

    private func rendererFor(_ device: TVDevice) async throws -> MediaRendererController {
        if let renderer, rendererDeviceID == device.id { return renderer }
        if checker.deviceID == device.id, let found = checker.renderer {
            renderer = found
            rendererDeviceID = device.id
            return found
        }
        guard let found = await MediaRendererController.locate(host: device.host, knownLocation: device.mediaRendererLocation) else {
            throw AppError.mediaRendererMissing
        }
        renderer = found
        rendererDeviceID = device.id
        return found
    }

    private func startPolling(sessionID: UUID) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTransport()
                try? await Task.sleep(for: .seconds(1))
                guard self?.castSessionID == sessionID else { return }
            }
        }
    }

    private func refreshTransport() async {
        guard let renderer else { return }
        transport = try? await renderer.transportState()
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain || ns.localizedDescription.localizedCaseInsensitiveContains("network")
    }

    private static func videoInfo(_ url: URL) async -> (duration: TimeInterval?, height: Int?) {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            height = Int(min(abs(rect.width), abs(rect.height)).rounded())
        }
        return (duration.flatMap { $0.isFinite ? $0 : nil }, height)
    }

    private static func videoThumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}
