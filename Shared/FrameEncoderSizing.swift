import Foundation

/// Frame size policy shared by the broadcast extension and tests.
enum FrameEncoderSizing {
    /// Target size with the long side capped and even dimensions (encoders prefer even sizes).
    static func targetSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxLongSide, longSide > 0 else { return (width & ~1, height & ~1) }
        let scale = Double(maxLongSide) / Double(longSide)
        return (Int(Double(width) * scale) & ~1, Int(Double(height) * scale) & ~1)
    }
}
