import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// Dedicated tests verifying that repeated headers, sticky navigation bars, and duplicate
/// content overlap regions are completely removed during horizontal and vertical stitching.
final class DeduplicationAndHeaderRemovalTests: XCTestCase {

    private func loadImage(named name: String, ext: String = "jpg") throws -> PlatformImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: ext),
              let image = PlatformImage(contentsOfFile: url.path) else {
            throw XCTSkip("Could not load \(name).\(ext) from test resources.")
        }
        return image
    }

    private func loadCGImage(named name: String, ext: String = "jpg") throws -> CGImage {
        let image = try loadImage(named: name, ext: ext)
        guard let cgImage = image.cgImage else {
            throw XCTSkip("Could not obtain CGImage for \(name).\(ext).")
        }
        return cgImage
    }

    // MARK: - 1. Horizontal Carousel Header & Footer Removal

    /// Verifies that horizontal carousel stitching strips out static headers and footers,
    /// ensuring NO repeated headers exist in the stitched horizontal strip.
    @MainActor
    func testHorizontalCarouselRemovesRepeatedHeadersAndFooters() async throws {
        let h1 = try loadImage(named: "horizontal")
        let h2 = try loadImage(named: "horizontal2")

        let results = try await ShotsToStitchesConverter.stitch(images: [h1, h2])

        XCTAssertEqual(results.count, 1, "Should produce 1 carousel strip.")
        guard let strip = results.first, let stripCG = strip.cgImage, let h1CG = h1.cgImage else {
            XCTFail("Failed to read carousel result image.")
            return
        }

        // The original frame contains a static top header ("Babka...") and static bottom rows.
        // The resulting carousel strip must be cropped to ONLY the changing card band.
        let originalHeight = h1CG.height
        let stripHeight = stripCG.height

        XCTAssertLessThan(
            Double(stripHeight),
            Double(originalHeight) * 0.70,
            "The horizontal strip must strip static headers/footers, reducing overall height."
        )

        // The strip width should be 2x original width (two cards side by side)
        XCTAssertEqual(stripCG.width, h1CG.width * 2, "Strip width must equal 2x original width.")
    }

    // MARK: - 2. Vertical Scroll Chrome & Overlap Deduplication

    /// Verifies that vertical scrolling on Pinterest removes floating header bars and bottom pills
    /// so they do not duplicate across the stitch seam.
    @MainActor
    func testVerticalScrollDeduplicatesStickyChromeAndOverlap() async throws {
        let pin1 = try loadImage(named: "pinterest1")
        let pin2 = try loadImage(named: "pinterest2")

        let results = try await ShotsToStitchesConverter.stitch(images: [pin1, pin2])

        XCTAssertEqual(results.count, 1, "Pinterest scroll must produce 1 panorama.")
        guard let panorama = results.first, let panoCG = panorama.cgImage, let pin1CG = pin1.cgImage else {
            XCTFail("Failed to read panorama image.")
            return
        }

        // Check that the stitch height is strictly LESS than 2x original frame height
        // (because the overlap and duplicate chrome was removed, not simply stacked)
        let twoFrameHeight = pin1CG.height * 2
        XCTAssertLessThan(
            panoCG.height,
            twoFrameHeight - 200,
            "Stitched panorama must eliminate duplicate overlap and chrome, not double the height."
        )

        // Check for any anomalous all-white bands in the panorama
        let thumbWidth = 64
        let thumbHeight = 256
        guard let thumb = testGrayscaleThumbnail(
            from: panoCG,
            width: thumbWidth,
            height: thumbHeight
        ) else {
            XCTFail("Could not extract diagnostic thumbnail.")
            return
        }

        var longestBlankRun = 0
        var currentBlankRun = 0

        for y in 0..<thumbHeight {
            let offset = y * thumbWidth
            let rowMean = thumb[offset..<(offset + thumbWidth)].reduce(0, { $0 + Double($1) }) / Double(thumbWidth)
            if rowMean > 248 {
                currentBlankRun += 1
                longestBlankRun = max(longestBlankRun, currentBlankRun)
            } else {
                currentBlankRun = 0
            }
        }

        XCTAssertLessThan(
            longestBlankRun,
            12,
            "Panorama must not contain large blank gaps caused by miscalculated chrome subtraction."
        )
    }
}
