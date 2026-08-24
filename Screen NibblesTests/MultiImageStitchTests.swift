import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// Dedicated tests verifying multi-image stitching for the Pinterest scenario.
final class MultiImageStitchTests: XCTestCase {

    private func loadImage(named name: String, ext: String = "jpg") throws -> PlatformImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: ext),
              let image = PlatformImage(contentsOfFile: url.path) else {
            throw XCTSkip("Could not load \(name).\(ext) from test resources.")
        }
        return image
    }

    @MainActor
    func testPinterestTwoFrameStitch() async throws {
        let pin1 = try loadImage(named: "pinterest1")
        let pin2 = try loadImage(named: "pinterest2")

        let results = try await ShotsToStitchesConverter.stitch(images: [pin1, pin2])

        if !results.isEmpty {
            try writeStitchOutputs(results, testName: "MultiImageStitchTests")
        }

        XCTAssertEqual(
            results.count, 1,
            "Pinterest 2-frame scroll must stitch into exactly one continuous vertical panorama."
        )

        guard let panorama = results.first, let cgImage = panorama.cgImage, let pin1CG = pin1.cgImage else {
            XCTFail("Failed to obtain CGImage from Pinterest stitch result.")
            return
        }

        // Panorama must be strictly portrait (width unchanged)
        XCTAssertEqual(cgImage.width, pin1CG.width, "Stitch width must match original screenshot width.")
        // Panorama height must exceed single frame height
        XCTAssertGreaterThan(cgImage.height, pin1CG.height, "Stitched panorama must be taller than a single screenshot.")
    }
}
