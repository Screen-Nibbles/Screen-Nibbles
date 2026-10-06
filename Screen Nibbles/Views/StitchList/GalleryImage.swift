import Foundation
import CoreGraphics
import ImageIO

/// Reads dimensions without decoding the full panorama.
struct GalleryImage: Sendable {
    let width: Int
    let height: Int

    nonisolated init?(data: Data?) {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        self.width = width
        self.height = height
    }

    var isHorizontal: Bool { width > height }
    var dimensions: String { "\(width) × \(height)" }

    /// Decode once off the interaction path. The old detail view recreated a
    /// platform image from JPEG data every time SwiftUI recomputed the body,
    /// which is especially expensive while pinching a very tall panorama.
    nonisolated static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    nonisolated static func thumbnail(data: Data, maxPixelSize: Int = 1200) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Callers choose a memory budget appropriate to the surface. Grid
            // cells use the default; the detail viewer can request a larger
            // but still bounded panorama preview.
            kCGImageSourceThumbnailMaxPixelSize: max(256, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
