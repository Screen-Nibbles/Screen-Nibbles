import Foundation
import ReplayKit
import AVFoundation
import ImageIO

/// ReplayKit invokes this handler serially. Keep the extension intentionally
/// small: it owns one hardware-backed AVAssetWriter at a time and publishes
/// only completed movie files through the shared App Group.
final class SampleHandler: RPBroadcastSampleHandler {
    private let groupID = "group.com.tomaslin.Screen-Nibbles"
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var partialURL: URL?
    private var dimensions: CMVideoDimensions?
    private var orientation: UInt32 = 1
    private var paused = false
    private var sessionURL: URL?
    private var segmentIndex = 0
    private var appendedFrames = 0
    private var terminalErrorRaised = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        writer = nil
        input = nil
        partialURL = nil
        dimensions = nil
        paused = false
        segmentIndex = 0
        appendedFrames = 0
        terminalErrorRaised = false

        do {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
                throw recordingError("Shared recording storage is unavailable. Enable the Screen Nibbles App Group for both targets.")
            }
            let session = container.appendingPathComponent("Recordings", isDirectory: true)
                .appendingPathComponent("\(UUID()).partial", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            sessionURL = session
        } catch {
            failBroadcast(error)
        }
    }

    /// Splitting at pause boundaries avoids a long timestamp hole in the movie,
    /// which otherwise looks like a frozen/incomplete frame to the stitcher.
    override func broadcastPaused() {
        paused = true
        do { try finishSegment() }
        catch { failBroadcast(error) }
    }

    override func broadcastResumed() {
        guard !terminalErrorRaised else { return }
        paused = false
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard !terminalErrorRaised,
              !paused,
              sampleBufferType == .video,
              CMSampleBufferDataIsReady(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        autoreleasepool {
            do {
                let size = CMVideoFormatDescriptionGetDimensions(format)
                guard size.width > 0, size.height > 0 else { return }

                let rawOrientation = (
                    CMGetAttachment(
                        sampleBuffer,
                        key: RPVideoSampleOrientationKey as CFString,
                        attachmentModeOut: nil
                    ) as? NSNumber
                )?.uint32Value ?? 1

                if let dimensions,
                   dimensions.width != size.width || dimensions.height != size.height || orientation != rawOrientation {
                    try finishSegment()
                }

                if writer == nil {
                    try startSegment(
                        size: size,
                        orientation: rawOrientation,
                        time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    )
                }

                guard let writer, let input else { return }
                if writer.status == .failed {
                    throw writer.error ?? recordingError("Screen recording failed.")
                }

                // Never block ReplayKit's serial callback waiting on the encoder.
                // If hardware encoding is momentarily back-pressured, dropping one
                // frame is safer than growing memory or stalling the extension.
                guard input.isReadyForMoreMediaData else { return }
                guard input.append(sampleBuffer) else {
                    throw writer.error ?? recordingError("Could not save a screen recording frame.")
                }
                appendedFrames += 1
            } catch {
                failBroadcast(error)
            }
        }
    }

    override func broadcastFinished() {
        // The user has already asked ReplayKit to stop. Preserve every segment
        // that did finish even if the final encoder flush fails; don't attempt a
        // second stop from inside broadcastFinished().
        do { try finishSegment() }
        catch { cancelCurrentSegment() }
        try? publishSession()
    }

    private func startSegment(size: CMVideoDimensions, orientation: UInt32, time: CMTime) throws {
        guard let directory = sessionURL else {
            throw recordingError("Shared recording storage is unavailable.")
        }

        segmentIndex += 1
        appendedFrames = 0
        let filename = String(format: "%04d.partial.mov", segmentIndex)
        let url = directory.appendingPathComponent(filename)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Text-heavy screen content benefits from a reasonably high bitrate,
        // while a bounded rate keeps the extension's encoder and file I/O from
        // being overwhelmed on long captures.
        let pixels = max(1, Int(size.width) * Int(size.height))
        let averageBitRate = min(12_000_000, max(4_000_000, pixels * 3))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        input.expectsMediaDataInRealTime = true

        let w = CGFloat(size.width), h = CGFloat(size.height)
        switch CGImagePropertyOrientation(rawValue: orientation) ?? .up {
        case .right:
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .left:
            input.transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .down:
            input.transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        default:
            break
        }

        guard writer.canAdd(input) else {
            throw recordingError("Unsupported screen recording format.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? recordingError("Could not start recording.")
        }
        writer.startSession(atSourceTime: time)

        self.writer = writer
        self.input = input
        partialURL = url
        dimensions = size
        self.orientation = orientation
    }

    /// Only finalized files receive a ready filename; the containing app never
    /// reads the writer's live `.partial.mov` file.
    private func finishSegment() throws {
        guard let writer, let input, let url = partialURL else { return }
        defer {
            self.writer = nil
            self.input = nil
            partialURL = nil
            dimensions = nil
            appendedFrames = 0
        }

        guard appendedFrames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }

        guard finished.wait(timeout: .now() + 5) == .success,
              writer.status == .completed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? recordingError("Could not finish the screen recording. Please try a shorter capture.")
        }

        let readyURL = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("mov")
        try FileManager.default.moveItem(at: url, to: readyURL)
    }

    private func cancelCurrentSegment() {
        writer?.cancelWriting()
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        writer = nil
        input = nil
        partialURL = nil
        dimensions = nil
        appendedFrames = 0
    }

    private func failBroadcast(_ error: Error) {
        guard !terminalErrorRaised else { return }
        terminalErrorRaised = true
        cancelCurrentSegment()
        try? publishSession()
        finishBroadcastWithError(error)
    }

    private func publishSession() throws {
        guard let sessionURL else { return }
        let files = try FileManager.default.contentsOfDirectory(at: sessionURL, includingPropertiesForKeys: [.fileSizeKey])
        let hasFinishedMovie = files.contains { file in
            guard file.pathExtension.lowercased() == "mov", !file.lastPathComponent.contains(".partial.") else { return false }
            return ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }

        if hasFinishedMovie {
            let destination = sessionURL.deletingPathExtension().appendingPathExtension("capture")
            try FileManager.default.moveItem(at: sessionURL, to: destination)
        } else {
            try? FileManager.default.removeItem(at: sessionURL)
        }
        self.sessionURL = nil
    }

    private func recordingError(_ message: String) -> NSError {
        NSError(domain: "ScreenNibbles", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
