
import Foundation
import CoreGraphics

/// Renders a `CGImage` into an 8-bit grayscale byte buffer for cheap
/// pixel-level assertions (e.g. detecting blank bands) in tests.
func testGrayscaleThumbnail(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
          ) else { return nil }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }

    let buffer = UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self),
        count: width * height
    )
    return Array(buffer)
}

extension Bundle {
    /// Finds `name.ext` anywhere in this bundle, including inside nested
    /// resource folders such as Screen NibblesTests/Samples/<feature>/.
    func testResourceURL(forResource name: String, withExtension ext: String) -> URL? {
        if let flat = url(forResource: name, withExtension: ext) {
            return flat
        }

        guard let resourceRoot = resourceURL else { return nil }

        let targetFilename = "\(name).\(ext)"
        let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == targetFilename {
                return candidate
            }
        }

        return nil
    }
}
