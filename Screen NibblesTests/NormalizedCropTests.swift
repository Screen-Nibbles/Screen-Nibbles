import XCTest
import CoreGraphics
@testable import Screen_Nibbles

final class NormalizedCropTests: XCTestCase {
    func testPreviewSelectionMapsToFullResolutionPixels() throws {
        let crop = NormalizedCrop(rect: CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.pixelRect(width: 1000, height: 2000), CGRect(x: 125, y: 500, width: 500, height: 1000))
        XCTAssertEqual(crop.pixelRect(width: 200, height: 400), CGRect(x: 25, y: 100, width: 100, height: 200))
    }

    func testOutOfBoundsAndEmptySelections() {
        let crop = NormalizedCrop(rect: CGRect(x: -0.25, y: 0.5, width: 1.5, height: 1))
        XCTAssertEqual(crop.pixelRect(width: 100, height: 200), CGRect(x: 0, y: 100, width: 100, height: 100))
        XCTAssertNil(NormalizedCrop(rect: .zero).pixelRect(width: 100, height: 200))
        XCTAssertNil(crop.pixelRect(width: 0, height: 200))
    }

    func testCropUsesTopLeftImageCoordinates() throws {
        // Top half red, bottom half blue: a selection below the midpoint must yield blue.
        let bytes: [UInt8] = [255,0,0,255, 255,0,0,255, 0,0,255,255, 0,0,255,255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let source = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let area = NormalizedCrop(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let cropped = try XCTUnwrap(source.cropping(to: try XCTUnwrap(area.pixelRect(width: 2, height: 2))))
        let data = try XCTUnwrap(cropped.dataProvider?.data)
        let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[2], 255)
    }

    func testFrameSelectionsAreIndependentAndPersistThroughEncoding() throws {
        let selections = [
            "1000": NormalizedCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            "2000": NormalizedCrop(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        ]
        let data = try JSONEncoder().encode(selections)
        let restored = try JSONDecoder().decode([String: NormalizedCrop].self, from: data)
        XCTAssertEqual(restored, selections)
        XCTAssertNotEqual(restored["1000"], restored["2000"])
    }
}
