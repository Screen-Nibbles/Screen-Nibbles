
import Foundation
import CoreGraphics
import XCTest
@testable import Screen_Nibbles

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

extension XCTestCase {
    /// Writes each stitched panorama to `test_output/<testName>/stitched_<i>.jpg`,
    /// resolved next to the project rather than inside DerivedData, so results can
    /// be inspected visually after a run.
    ///
    /// Call this from any test whenever `ShotsToStitchesConverter.stitch(images:)`
    /// produces at least one result, right after the stitch call so output is
    /// written even if later assertions in the test fail.
    ///
    /// `callerFilePath` defaults to `#filePath`, which Swift resolves at each call
    /// site — so every test automatically writes into a directory computed from
    /// its own source file location, with no extra plumbing needed.
    @discardableResult
    func writeStitchOutputs(
        _ images: [PlatformImage],
        testName: String,
        callerFilePath: StaticString = #filePath
    ) throws -> URL {
        let projectRoot = URL(fileURLWithPath: "\(callerFilePath)")
            .deletingLastPathComponent() // Screen NibblesTests/
            .deletingLastPathComponent() // repo root

        let outputDir = projectRoot
            .appendingPathComponent("test_output")
            .appendingPathComponent(testName)

        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                XCTFail("Stitched image \(index) for \(testName) failed to encode")
                continue
            }
            try data.write(to: outputDir.appendingPathComponent("stitched_\(index).jpg"))
        }

        return outputDir
    }
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
