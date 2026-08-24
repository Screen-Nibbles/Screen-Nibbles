import XCTest
import AVFoundation
@testable import Screen_Nibbles

final class ParseFVRVideoAndStitchTests: XCTestCase {

    /// Repo root, resolved from this source file's own on-disk path so the
    /// test writes its output next to the project rather than DerivedData.
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screen NibblesTests/
            .deletingLastPathComponent() // repo root
    }

    private func longestNearWhiteRun(
        in image: CGImage,
        width: Int = 64,
        height: Int = 512
    ) -> Int {
        guard let pixels = testGrayscaleThumbnail(from: image, width: width, height: height) else {
            return height
        }

        var longest = 0
        var current = 0
        for y in 0..<height {
            let rowStart = y * width
            let mean = pixels[rowStart..<(rowStart + width)]
                .reduce(0.0) { $0 + Double($1) } / Double(width)
            if mean > 245 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    @MainActor
    func testParseFVRVideoAndStitch() async throws {
        let bundle = Bundle(for: type(of: self))
        guard let videoURL = bundle.testResourceURL(forResource: "test_video", withExtension: "mp4") else {
            XCTFail("Could not find test_video.mp4 in the test bundle. Please add it to the Screen NibblesTests target.")
            return
        }

        // Extract frames using the real production pipeline: this reads the
        // video's own variable frame rate, finds its pause windows, and
        // pulls one representative frame per pause.
        let extractedFrames = try await VideoToShotsConverter.extractFrames(from: videoURL)

        XCTAssertGreaterThan(
            extractedFrames.count, 1,
            "Need at least 2 frames to stitch — is test_video.mp4 actually variable-frame-rate?"
        )

        // Stitch the extracted frames together using the real pipeline
        // (Vision-based alignment + compositing).
        let stitchedImages = try await ShotsToStitchesConverter.stitch(images: extractedFrames.map(\.image))

        guard !stitchedImages.isEmpty else {
            XCTFail("Stitching produced no images")
            return
        }

        XCTAssertEqual(
            stitchedImages.count,
            1,
            "test_video.mp4 is one continuous vertical scroll; a correct stitch must not split it into multiple panoramas."
        )

        if let stitched = stitchedImages.first, let cgImage = stitched.cgImage {
            // The eight extracted frames are 924x2000 portrait screenshots.
            // Their measured scrolls put the final panorama around 5-7k px tall.
            XCTAssertEqual(
                cgImage.width,
                924,
                "The final video stitch must remain portrait; horizontal growth is a regression."
            )
            XCTAssertGreaterThan(
                cgImage.height,
                5000,
                "The final panorama is too short to contain all eight scroll positions."
            )
            XCTAssertLessThan(
                cgImage.height,
                7000,
                "The final panorama is too tall; this usually means a wrong shift or duplicated chrome."
            )

            // A bad vertical merge can create a large white gap when the
            // fixed bottom chrome is subtracted from the overlap but the
            // overlay isn't translated by the same amount. The source
            // frames provide the baseline for how much white space is legitimate.
            let sourceBlankBaseline = extractedFrames
                .compactMap { $0.image.cgImage }
                .map { longestNearWhiteRun(in: $0) }
                .max() ?? 0
            let stitchedBlankRun = longestNearWhiteRun(in: cgImage)
            XCTAssertLessThanOrEqual(
                stitchedBlankRun,
                sourceBlankBaseline + 40,
                "The final panorama contains a new large white band (stitched: \(stitchedBlankRun), source baseline: \(sourceBlankBaseline))."
            )
        } else {
            XCTFail("The first stitched image could not be read as a CGImage.")
        }

        // Write the extracted (pre-stitch) frames for visual inspection.
        let soloDir = projectRoot
            .appendingPathComponent("test_output")
            .appendingPathComponent("solo")
        try? FileManager.default.removeItem(at: soloDir)
        try FileManager.default.createDirectory(at: soloDir, withIntermediateDirectories: true)

        for (index, frame) in extractedFrames.enumerated() {
            guard let data = frame.image.jpegData(compressionQuality: 0.9) else {
                XCTFail("Frame \(index) at \(frame.timestamp)s failed to encode")
                continue
            }
            let filename = String(format: "frame_%02d_%.2fs.jpg", index, frame.timestamp)
            try data.write(to: soloDir.appendingPathComponent(filename))
        }

        // Write the stitched panorama(s) using the shared helper so every
        // stitch-producing test leaves output behind the same way.
        if !stitchedImages.isEmpty {
            try writeStitchOutputs(stitchedImages, testName: "stitched")
        }
    }
}
