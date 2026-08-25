import XCTest
import CoreGraphics
@testable import Screen_Nibbles

final class ReplaceStitchTests: XCTestCase {

    private func loadImage(named name: String) throws -> PlatformImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.testResourceURL(forResource: name, withExtension: "jpg"),
              let image = PlatformImage(contentsOfFile: url.path) else {
            throw XCTSkip("Could not load \(name).jpg from the test resources.")
        }
        return image
    }

    @MainActor
    func testReplaceOverlapsCorrectly() async throws {
        let images = [
            try loadImage(named: "replace1"),
            try loadImage(named: "replace2"),
            try loadImage(named: "replace3")
        ]

        let results = try await ShotsToStitchesConverter.stitch(images: images)

        if !results.isEmpty {
            try writeStitchOutputs(results, testName: "ReplaceStitchTests")
        }

        XCTAssertEqual(
            results.count,
            1,
            "replace1 and replace2 should stitch into a single panorama despite the disconnect at the bottom."
        )

        guard let result = results.first, let cgImage = result.cgImage else {
            XCTFail("Replace stitching returned no readable panorama.")
            return
        }

        XCTAssertEqual(
            cgImage.width,
            924,
            "The stitch must stay portrait."
        )

        // They are essentially the same frame with a minor disconnect at the bottom.
        // Therefore, the stitched image should be about the same height as the input.
        XCTAssertEqual(
            Double(cgImage.height),
            2000.0,
            accuracy: 50.0,
            "The first file should get overriden at the correct placement by replace2. Height should remain around 2000."
        )
    }
}
