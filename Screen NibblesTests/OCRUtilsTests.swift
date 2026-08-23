import XCTest
import CoreGraphics
import ImageIO
@testable import Screen_Nibbles

/// Dedicated tests verifying `OCRUtils` text extraction, confidence scoring,
/// chrome keyword filtering, and line deduplication.
final class OCRUtilsTests: XCTestCase {

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

    // MARK: - 1. OCR Extraction on Real Screenshots

    /// Tests text extraction on real Pinterest screenshot containing visible pin titles and descriptions.
    func testPinterestTextExtraction() async throws {
        let cgImage = try loadCGImage(resource: "pinterest1")

        let result = try await OCRUtils.extractText(from: cgImage, options: .standard)

        XCTAssertFalse(result.fullText.isEmpty, "OCR should extract text from Pinterest screenshot.")
        XCTAssertGreaterThan(result.lines.count, 0, "OCR should identify multiple text lines.")
        XCTAssertGreaterThan(result.averageConfidence, 0.3, "Average recognition confidence should be high.")
    }

    // MARK: - 2. Filtering & Normalization Utilities

    /// Tests filtering of static navigation buttons and menu chrome strings.
    func testMenuAndChromeKeywordDetection() {
        XCTAssertTrue(OCRUtils.isMenuOrChrome("Home"))
        XCTAssertTrue(OCRUtils.isMenuOrChrome("Search"))
        XCTAssertTrue(OCRUtils.isMenuOrChrome("Settings"))
        XCTAssertTrue(OCRUtils.isMenuOrChrome("..."))
        XCTAssertTrue(OCRUtils.isMenuOrChrome("•••"))

        XCTAssertFalse(OCRUtils.isMenuOrChrome("Chocolate Babka Recipe with Cinnamon"))
        XCTAssertFalse(OCRUtils.isMenuOrChrome("Colorful Glass Arch Garden Path"))
    }

    /// Tests timestamp and date pattern matching.
    func testTimestampPatternDetection() {
        XCTAssertTrue(OCRUtils.isTimestamp("10:45 AM"))
        XCTAssertTrue(OCRUtils.isTimestamp("2:30 PM"))
        XCTAssertTrue(OCRUtils.isTimestamp("5 mins ago"))
        XCTAssertTrue(OCRUtils.isTimestamp("2 hrs ago"))

        XCTAssertFalse(OCRUtils.isTimestamp("The quick brown fox"))
        XCTAssertFalse(OCRUtils.isTimestamp("Step 1: Mix ingredients together"))
    }

    /// Tests text normalization for deduplication.
    func testTextNormalization() {
        let raw1 = "Hello, World! 123"
        let raw2 = "hello world 123"

        XCTAssertEqual(
            OCRUtils.normalizeText(raw1),
            OCRUtils.normalizeText(raw2),
            "Normalized strings should ignore punctuation and case differences."
        )
    }
}
