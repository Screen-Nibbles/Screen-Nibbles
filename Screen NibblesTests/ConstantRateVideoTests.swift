import XCTest
import AVFoundation
import CoreVideo
@testable import Screen_Nibbles

final class ConstantRateVideoTests: XCTestCase {
    @MainActor
    func testOrdinaryRecordingExtractsDistinctPausedScreens() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cfr-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 400
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 400])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            // Each screen stays still for a second, at constant 10fps.
            memset(base, Int32(50 + (frame / 10) * 80), CVPixelBufferGetBytesPerRow(pixels) * 400)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let shots = try await VideoToShotsConverter.extractFrames(from: url)
        XCTAssertEqual(shots.count, 3, "Constant-rate recordings must preserve each paused screen without duplicates.")
        XCTAssertEqual(shots.map(\.timestamp), shots.map(\.timestamp).sorted())
    }
}
