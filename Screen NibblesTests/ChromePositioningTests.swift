import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// Tests verifying iOS Control Center rejection on real-world mobile screenshots.
final class ChromePositioningTests: XCTestCase {

    private func loadCGImage(resource name: String, withExtension ext: String = "jpg") throws -> CGImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: ext) else {
            throw XCTSkip("Could not find \(name).\(ext) in the test bundle.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("Could not decode \(name).\(ext) as an image.")
        }
        return image
    }

    /// Tests that real iOS Control Center overlay screenshots are positively identified and skipped.
    func testRealControlCenterScreenshotsAreIdentified() throws {
        let control1 = try loadCGImage(resource: "control_image")
        XCTAssertTrue(
            FrameFilter.isIosControlCenter(control1),
            "control_image.jpg is a real Control Center overlay and must be recognized."
        )

        let control2 = try loadCGImage(resource: "control_image2")
        XCTAssertTrue(
            FrameFilter.isIosControlCenter(control2),
            "control_image2.jpg is a real Control Center overlay and must be recognized."
        )
    }

    /// Tests that regular content frames are NOT falsely flagged as Control Center.
    func testRegularContentIsNotFlaggedAsControlCenter() throws {
        let nonControl = try loadCGImage(resource: "non_control")
        XCTAssertFalse(
            FrameFilter.isIosControlCenter(nonControl),
            "non_control.jpg is ordinary content and must not be flagged as Control Center."
        )
    }
}
