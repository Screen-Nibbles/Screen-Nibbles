import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// End-to-end coverage for the `mixed` sample: a single capture that starts
/// with four frames of a top-of-page carousel swipe (only the hero image
/// band changes), then continues into three frames of real vertical
/// scrolling further down the same page.
///
/// This is the scenario the frame-transition classifier
/// (`ShotsToStitchesConverter`'s vertical / horizontal / mismatch pipeline)
/// exists for: a single `stitch(images:)` call spanning both should NOT
/// collapse into one broken panorama, and should NOT silently drop the
/// carousel frames the way overlaying every near-zero-shift pair used to.
final class MixedShotSplittingTests: XCTestCase {

    /// In on-disk/lexical order: the first four are the carousel swipe
    /// (only the hero band changes), the last three are real vertical
    /// scroll continuations further down the page.
    private static let frameNames = [
        "horizontal", "horizontal2", "horizontal3", "horizontal4",
        "horizontal5", "horizontal6", "hotizontsl7"
    ]

    private func loadImage(named name: String, ext: String = "jpg") throws -> PlatformImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: ext),
              let image = PlatformImage(contentsOfFile: url.path) else {
            throw XCTSkip("Could not load \(name).\(ext) from test resources.")
        }
        return image
    }

    @MainActor
    func testMixedCaptureSplitsIntoOneCarouselStripAndOneVerticalPanorama() async throws {
        let images = try Self.frameNames.map { try loadImage(named: $0) }
        guard let originalCG = images.first?.cgImage else {
            XCTFail("Could not read a CGImage from the first mixed frame.")
            return
        }

        let results = try await ShotsToStitchesConverter.stitch(images: images)

        if !results.isEmpty {
            try writeStitchOutputs(results, testName: "MixedShotSplittingTests")
        }

        XCTAssertEqual(
            results.count,
            2,
            "The mixed capture is one carousel swipe followed by one vertical scroll continuation; " +
            "it must split into exactly 2 images (1 carousel strip + 1 vertical panorama), not \(results.count)."
        )
        guard results.count == 2 else { return }

        let cgImages = results.compactMap { $0.cgImage }
        XCTAssertEqual(cgImages.count, 2, "Both stitch results must be readable as CGImages.")
        guard cgImages.count == 2 else { return }

        // Identify which of the two results is the carousel strip (wider
        // than the original frame — cards laid out side by side) versus the
        // vertical panorama (same width as the original, taller).
        let carousels = cgImages.filter { $0.width > originalCG.width }
        let verticals = cgImages.filter { $0.width == originalCG.width }

        XCTAssertEqual(carousels.count, 1, "Exactly one result should be a wider-than-original carousel strip.")
        XCTAssertEqual(verticals.count, 1, "Exactly one result should be a same-width vertical panorama.")
        guard let carousel = carousels.first, let vertical = verticals.first else { return }

        // The carousel run spans frames 1-4 (horizontal, horizontal2,
        // horizontal3, horizontal4) — 4 cards laid out side by side.
        XCTAssertEqual(
            carousel.width,
            originalCG.width * 4,
            "Carousel strip should contain all 4 swiped cards side by side."
        )
        XCTAssertLessThan(
            Double(carousel.height),
            Double(originalCG.height) * 0.70,
            "Carousel strip must be cropped to only the changing hero band, not the full frame height."
        )

        // The vertical panorama covers the scroll continuation further down
        // the page (horizontal4/5 -> horizontal6 -> hotizontsl7); it must
        // stay portrait and be taller than a single screenshot.
        XCTAssertGreaterThan(
            vertical.height,
            originalCG.height,
            "Vertical panorama must be taller than a single screenshot — it should contain multiple scroll positions."
        )

        // Neither result should be a degenerate sliver.
        XCTAssertGreaterThan(carousel.height, 0)
        XCTAssertGreaterThan(vertical.width, 0)
    }
}
