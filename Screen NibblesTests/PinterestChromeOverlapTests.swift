import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// `pinterest1.jpg` and `pinterest2.jpg` are two real, consecutive
/// screenshots from a Pinterest scroll capture with substantial real
/// content overlap, but two pieces of fixed UI chrome (a floating tab
/// pill at the bottom of frame 1, a fixed status bar + category row at
/// the top of frame 2) that must not defeat the alignment search.
final class PinterestChromeOverlapTests: XCTestCase {

    /// End-to-end check: stitching these two real frames should produce
    /// ONE continuous panorama, not two.
    @MainActor
    func testPinterestFramesStitchIntoOnePanorama() async throws {
        let bundle = Bundle(for: type(of: self))
        guard let url1 = bundle.testResourceURL(forResource: "pinterest1", withExtension: "jpg"),
              let url2 = bundle.testResourceURL(forResource: "pinterest2", withExtension: "jpg"),
              let image1 = PlatformImage(contentsOfFile: url1.path),
              let image2 = PlatformImage(contentsOfFile: url2.path) else {
            throw XCTSkip("Could not load pinterest1.jpg / pinterest2.jpg from the test bundle.")
        }

        let stitched = try await ShotsToStitchesConverter.stitch(images: [image1, image2])

        XCTAssertEqual(
            stitched.count, 1,
            "pinterest1.jpg and pinterest2.jpg overlap substantially and should stitch into a single panorama, not split into \(stitched.count)."
        )
    }
}
