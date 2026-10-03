import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Scales a captured screen buffer and encodes it as JPEG, reusing buffers to stay well
/// inside the broadcast extension's memory budget (~50 MB, undocumented).
final class FrameEncoder {
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    init() {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession)
        if let transferSession {
            VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
    }

    deinit {
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    func encode(_ source: CVPixelBuffer, maxLongSide: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let transferSession else { return nil }
        let size = FrameEncoderSizing.targetSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source), maxLongSide: maxLongSide)
        guard size.width > 0, size.height > 0 else { return nil }
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attributes as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination, VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination) == noErr else { return nil }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(destination, options: nil, imageOut: &image)
        guard let image else { return nil }
        let output = NSMutableData()
        guard let jpeg = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(jpeg, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg) else { return nil }
        return (output as Data, size.width, size.height)
    }
}

extension CGImagePropertyOrientation {
    /// Clockwise quarter turns the receiver must apply to show the frame upright.
    var receiverQuarterTurns: UInt8 {
        switch self {
        case .left, .leftMirrored: 3
        case .right, .rightMirrored: 1
        case .down, .downMirrored: 2
        default: 0
        }
    }
}
