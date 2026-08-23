import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// Regression coverage for screenshots captured while scrolling upward.
///
/// The input order is intentionally reverse-lexical: up4 -> up3 -> up2 ->
/// up1. In CoreGraphics pixel coordinates a frame that appears above the
/// previous frame has a POSITIVE Y translation.
final class GoingUpStitchTests: XCTestCase {

    private static let frameNames = ["up4", "up3", "up2", "up1"]

    private func loadImage(named name: String) throws -> PlatformImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: "jpg"),
              let image = PlatformImage(contentsOfFile: url.path) else {
            throw XCTSkip("Could not load \(name).jpg from the goingUp test resources.")
        }
        return image
    }

    @MainActor
    func testGoingUpStitchesIntoOneCorrectVerticalPanorama() async throws {
        let images = try Self.frameNames.map { try loadImage(named: $0) }

        let results = try await ShotsToStitchesConverter.stitch(images: images)

        XCTAssertEqual(
            results.count,
            1,
            "The four going-up frames are one continuous vertical capture; they must not become multiple panoramas."
        )
        guard let result = results.first, let cgImage = result.cgImage else {
            XCTFail("Going-up stitching returned no readable panorama.")
            return
        }

        XCTAssertEqual(
            cgImage.width,
            924,
            "The stitch must stay portrait. A horizontal false-positive would increase the width."
        )

        // The measured frame-to-frame translations are approximately
        // +1424, +685 and +578 px in this sample, so a correct four-frame
        // panorama is about 4,687 px tall. Allow some room for chrome
        // removal/rounding.
        XCTAssertGreaterThan(
            cgImage.height,
            4200,
            "The result is too short to contain all four upward scroll positions."
        )
        XCTAssertLessThan(
            cgImage.height,
            5100,
            "The result is too tall; this usually means a wrong-direction or horizontal false-positive merge."
        )

        let thumbWidth = 64
        let thumbHeight = 512
        guard let pixels = testGrayscaleThumbnail(
            from: cgImage,
            width: thumbWidth,
            height: thumbHeight
        ) else {
            XCTFail("Could not create a diagnostic thumbnail of the panorama.")
            return
        }

        var longestBlankRun = 0
        var currentBlankRun = 0

        for y in 0..<thumbHeight {
            let offset = y * thumbWidth
            let mean = pixels[offset..<(offset + thumbWidth)]
                .reduce(0.0) { $0 + Double($1) } / Double(thumbWidth)

            if mean > 245 {
                currentBlankRun += 1
                longestBlankRun = max(longestBlankRun, currentBlankRun)
            } else {
                currentBlankRun = 0
            }
        }

        XCTAssertLessThan(
            longestBlankRun,
            20,
            "The final panorama contains a large blank band (longest run: \(longestBlankRun) thumbnail rows)."
        )
    }
}
