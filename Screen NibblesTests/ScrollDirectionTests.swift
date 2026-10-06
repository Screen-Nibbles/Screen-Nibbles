import XCTest
import CoreGraphics
@testable import Screen_Nibbles

final class ScrollDirectionTests: XCTestCase {
    private func page() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 1200,
            bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1200))
        var seed: UInt64 = 193
        for _ in 0..<1200 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = CGFloat((seed >> 16) % 1000), y = CGFloat((seed >> 32) % 1200)
            context.setFillColor(CGColor(red: CGFloat(seed % 255) / 255,
                green: CGFloat((seed >> 8) % 255) / 255, blue: CGFloat((seed >> 24) % 255) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 15 + CGFloat(seed % 60), height: 15 + CGFloat((seed >> 8) % 60)))
        }
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    func testBothAxesAndReversalsPreserveThePageExtent() async throws {
        let page = try page()
        func frame(_ x: Int, _ y: Int) throws -> PlatformImage {
            .from(cgImage: try XCTUnwrap(page.cropping(to: CGRect(x: x, y: y, width: 400, height: 500))))
        }
        let scenarios: [(String, [(Int, Int)], Int, Int)] = [
            ("down", [(0,0), (0,200), (0,400)], 400, 900),
            ("up", [(0,400), (0,200), (0,0)], 400, 900),
            ("vertical reversal", [(0,0), (0,200), (0,0)], 400, 700),
            ("right", [(0,0), (150,0), (300,0)], 700, 500),
            ("left", [(300,0), (150,0), (0,0)], 700, 500),
            ("horizontal reversal", [(0,0), (150,0), (0,0)], 550, 500)
        ]
        for (name, positions, width, height) in scenarios {
            let images = try positions.map { try frame($0.0, $0.1) }
            let results = try await ShotsToStitchesConverter.stitch(images: images)
            XCTAssertEqual(results.count, 1, name)
            let output = try XCTUnwrap(results.first?.cgImage)
            XCTAssertEqual(output.width, width, accuracy: 3, name)
            XCTAssertEqual(output.height, height, accuracy: 3, name)
            // Compare actual rendered pixels to the source page, catching seams and flipped rows.
            let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)))
            let a = try XCTUnwrap(testGrayscaleThumbnail(from: output, width: 100, height: 100))
            let b = try XCTUnwrap(testGrayscaleThumbnail(from: expected, width: 100, height: 100))
            let meanError = zip(a,b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
            XCTAssertLessThan(meanError, 4, name)
        }
    }

    @MainActor
    func testOrientationChangeProducesSeparateImages() async throws {
        let source = try page()
        let images = [CGRect(x: 0, y: 0, width: 400, height: 500), CGRect(x: 0, y: 0, width: 500, height: 400)]
            .map { PlatformImage.from(cgImage: source.cropping(to: $0)!) }
        let results = try await ShotsToStitchesConverter.stitch(images: images)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].cgImage?.width, 400)
        XCTAssertEqual(results[1].cgImage?.width, 500)
    }

    @MainActor
    func testSingleBrokenMiddleFrameIsBridgedInsteadOfSplittingScroll() async throws {
        let source = try page()
        func frame(_ y: Int) throws -> PlatformImage {
            .from(cgImage: try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: y, width: 400, height: 500))))
        }

        let brokenContext = try XCTUnwrap(CGContext(data: nil, width: 400, height: 500,
            bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        brokenContext.setFillColor(CGColor(gray: 0.02, alpha: 1))
        brokenContext.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        brokenContext.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        brokenContext.fill(CGRect(x: 0, y: 210, width: 400, height: 35))
        let broken = PlatformImage.from(cgImage: try XCTUnwrap(brokenContext.makeImage()))

        let results = try await ShotsToStitchesConverter.stitch(images: [
            try frame(0), broken, try frame(200), try frame(400)
        ])

        XCTAssertEqual(results.count, 1)
        let output = try XCTUnwrap(results.first?.cgImage)
        XCTAssertEqual(output.width, 400, accuracy: 3)
        XCTAssertEqual(output.height, 900, accuracy: 6)
    }
}
