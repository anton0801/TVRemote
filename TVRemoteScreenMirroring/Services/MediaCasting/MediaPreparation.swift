import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A picked video copied into our temporary cast folder (only the file the user selected).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = try MediaWorkspace.makeTemporaryURL(extension: received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

/// Temporary files for casting. Cleared on stop, cancel and at launch (crash recovery).
enum MediaWorkspace {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cast", isDirectory: true)
    }

    static func makeTemporaryURL(extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func remove(_ url: URL?) {
        guard let url, url.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func availableCapacity() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

enum PhotoFitMode: String, CaseIterable, Sendable {
    /// Whole photo visible; the TV adds bars if needed (default — never crops unexpectedly).
    case fit
    /// Photo cropped to 16:9 to fill the screen.
    case fill
}

enum MediaPreparation {
    /// Converts any picked image (HEIC, PNG, JPEG…) into an upright JPEG the TV can decode.
    static func jpegForTV(from data: Data, mode: PhotoFitMode, maxPixel: Int = 3840) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw AppError.mediaFormatUnsupported }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bakes EXIF orientation in
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AppError.mediaFormatUnsupported }
        if mode == .fill, let cropped = cropToAspect(image, aspect: 16.0 / 9.0) { image = cropped }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppError.mediaFormatUnsupported }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.mediaFormatUnsupported }
        return output as Data
    }

    static func cropToAspect(_ image: CGImage, aspect: CGFloat) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let current = width / height
        let rect: CGRect
        if current > aspect {
            let newWidth = height * aspect
            rect = CGRect(x: (width - newWidth) / 2, y: 0, width: newWidth, height: height)
        } else {
            let newHeight = width / aspect
            rect = CGRect(x: 0, y: (height - newHeight) / 2, width: width, height: newHeight)
        }
        return image.cropping(to: rect.integral)
    }

    struct VideoInfo: Sendable {
        let duration: TimeInterval
        let isH264: Bool
        let hasAudio: Bool
        let isMP4Container: Bool
    }

    static func inspectVideo(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw AppError.mediaFormatUnsupported }
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw AppError.mediaFormatUnsupported }
        let formats = try await track.load(.formatDescriptions)
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return VideoInfo(duration: duration, isH264: isH264, hasAudio: !audio.isEmpty, isMP4Container: url.pathExtension.lowercased() == "mp4")
    }

    /// Produces an MP4 (H.264/AAC) most TV renderers accept: passthrough re-wrap when already
    /// H.264, otherwise a 1080p transcode. Reports progress; cancellable; checks free space.
    static func exportForTV(_ source: URL, info: VideoInfo, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        if info.isH264 && info.isMP4Container { return source }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let free = MediaWorkspace.availableCapacity(), free < fileSize * 2 + 50_000_000 {
            throw AppError.mediaInsufficientStorage
        }
        let asset = AVURLAsset(url: source)
        let preset = info.isH264 ? AVAssetExportPresetPassthrough : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw AppError.mediaFormatUnsupported }
        let output = try MediaWorkspace.makeTemporaryURL(extension: "mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let box = ExportSessionBox(session)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        await withTaskCancellationHandler {
            await box.session.export()
        } onCancel: {
            box.session.cancelExport()
        }
        if Task.isCancelled || box.session.status == .cancelled {
            MediaWorkspace.remove(output)
            throw CancellationError()
        }
        guard box.session.status == .completed else {
            MediaWorkspace.remove(output)
            throw AppError.mediaFormatUnsupported
        }
        return output
    }
}

/// AVAssetExportSession is not Sendable; it is only touched on the export path above.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
