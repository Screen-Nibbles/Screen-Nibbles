import SwiftUI
import CoreGraphics
import CoreVideo
import ImageIO
import AVFoundation
import CoreImage
import Foundation
import os

// MARK: - Video to Shots Protocol

/// Protocol defining the interface for extracting representative shots from video recordings.
@MainActor
public protocol VideoToShotsConverting: Sendable {
    func convert(
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> [ExtractedShot]
}

// MARK: - Extracted Shot & Errors

/// Represents a single extracted frame (shot) before stitching.
public struct ExtractedShot: Sendable {
    public let timestamp: TimeInterval
    public let image: PlatformImage

    public init(timestamp: TimeInterval, image: PlatformImage) {
        self.timestamp = timestamp
        self.image = image
    }
}

/// Errors thrown while extracting shots from a video.
public enum VideoToShotsError: LocalizedError {
    case noVideoTrack
    case notVariableFrameRate

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in the selected file."
        case .notVariableFrameRate:
            return "This video isn't supported yet. Constant frame-rate processing is disabled."
        }
    }
}

// MARK: - Settle Hash

/// A tolerant frame fingerprint used by the settle-check.
///
/// Frames decoded from a lossy video track are never byte-identical between
/// frames — even of genuinely static screen content — so an exact hash would
/// never match. This reduces each frame to a small, noise-resistant digest:
/// 16x16 grayscale, quantized to 16 levels per pixel, so codec jitter only
/// flips a byte when a pixel sits right at a quantization boundary. Two
/// fingerprints "match" when at most a small fraction of their bytes differ,
/// which static content satisfies and any real scroll or content change
/// violates by a wide margin.
struct FrameSettleHash {
    private let bytes: [UInt8]

    private static let dimension = 16
    /// Max differing bytes (out of 256) still considered the same image.
    private static let maxMismatchedBytes = 10

    init?(cgImage: CGImage) {
        let size = Self.dimension
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: size * size)
        bytes = Array(UnsafeBufferPointer(start: buffer, count: size * size))
    }

    func matches(_ other: FrameSettleHash) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        var mismatches = 0
        for (a, b) in zip(bytes, other.bytes) where a != b {
            mismatches += 1
            if mismatches > Self.maxMismatchedBytes { return false }
        }
        return true
    }
}

// MARK: - Video to Shots Converter

/// Converts a screen recording video into a series of static shots by detecting pauses.
@MainActor
public final class VideoToShotsConverter: VideoToShotsConverting {
    private let maxFrameDimension: CGFloat = 2000
    private let analyzer = VideoFrameAnalyzer()

    public init() {}

    /// Static convenience method for extracting representative frames from a video.
    public static func extractFrames(
        from url: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [ExtractedShot] {
        let converter = VideoToShotsConverter()
        return try await converter.convert(from: url, progress: progress)
    }

    /// Extracts the representative shot for each pause found in the video.
    public func convert(
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> [ExtractedShot] {
        let asset = AVURLAsset(url: url)

        Log.frames.info("Loading video track for \(url.lastPathComponent, privacy: .public)")
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            Log.frames.error("No video track found in \(url.lastPathComponent, privacy: .public)")
            throw VideoToShotsError.noVideoTrack
        }

        guard let pauseWindows = try await analyzer.detectPauses(in: asset), !pauseWindows.isEmpty else {
            Log.frames.notice("\(url.lastPathComponent, privacy: .public) has no usable pause signal.")
            throw VideoToShotsError.notVariableFrameRate
        }

        Log.frames.info("Extracting a settled frame for each of \(pauseWindows.count, privacy: .public) native pause window(s)")
        let frames = try await extractSettledFrames(for: pauseWindows, from: asset, progress: progress)
        return frames
    }

    /// Fractions (of a pause window's duration) at which probe frames are
    /// sampled for the settle-check. Spans from just after the window opens
    /// to just before it closes so both "settled instantly" and "settled
    /// late" windows are bracketed.
    private static let settleProbeFractions: [Double] = [0.05, 0.275, 0.5, 0.725, 0.95]

    /// Extracts one settled frame per pause window.
    ///
    /// VFR timing alone says the encoder *held* a frame during each window;
    /// it doesn't guarantee the composited screen content was actually at
    /// rest there (scroll deceleration can smear across the window's start,
    /// and a long encoded gap can hide a brief flicker). So each window is
    /// probed at several timestamps and an explicit settle-check runs:
    /// consecutive probes are fingerprint-compared, and the latest probe
    /// whose fingerprint matches its predecessor is chosen — proof that the
    /// screen held still across that pair. If no consecutive pair ever
    /// matches, the window's midpoint is used as the fallback, matching the
    /// old VFR-only behavior.
    private func extractSettledFrames(
        for windows: [VideoFrameAnalyzer.PauseWindow],
        from asset: AVURLAsset,
        progress: @escaping (Double) -> Void
    ) async throws -> [ExtractedShot] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxFrameDimension, height: maxFrameDimension)

        var frames: [ExtractedShot] = []
        frames.reserveCapacity(windows.count)

        var decodeFailures = 0

        for (windowIndex, window) in windows.enumerated() {
            defer { progress(Double(windowIndex + 1) / Double(windows.count)) }

            let duration = max(0, window.endTime - window.startTime)
            let probeTimes = Self.settleProbeFractions.map {
                CMTime(seconds: window.startTime + duration * $0, preferredTimescale: 600)
            }

            var probes: [(time: TimeInterval, image: CGImage)] = []
            probes.reserveCapacity(probeTimes.count)
            for await result in generator.images(for: probeTimes) {
                guard case .success(let requestedTime, let cgImage, _) = result else {
                    decodeFailures += 1
                    continue
                }
                if FrameFilter.isIosControlCenter(cgImage) {
                    Log.frames.notice("Probe at \(requestedTime.seconds, format: .fixed(precision: 2), privacy: .public)s is iOS Control Center — skipping")
                    continue
                }
                probes.append((requestedTime.seconds, cgImage))
            }

            guard !probes.isEmpty else {
                Log.frames.notice("All probes failed to decode for pause window [\(window.startTime, format: .fixed(precision: 2), privacy: .public)s - \(window.endTime, format: .fixed(precision: 2), privacy: .public)s] — skipping")
                continue
            }

            // Settle-check: walk consecutive probe pairs; keep the LATEST
            // index that is part of a matching pair (the newest frame proven
            // static). Falls back to the middle probe when nothing settles,
            // which mirrors trusting the VFR midpoint alone.
            var settledIndex: Int?
            if probes.count >= 2 {
                let fingerprints = probes.map { FrameSettleHash(cgImage: $0.image) }
                for i in 1..<probes.count {
                    if let prev = fingerprints[i - 1], let curr = fingerprints[i],
                       prev.matches(curr) {
                        settledIndex = i
                    }
                }
            }

            let chosenIndex = settledIndex ?? probes.count / 2
            if let settledIndex {
                Log.frames.debug("Pause window [\(window.startTime, format: .fixed(precision: 2), privacy: .public)s - \(window.endTime, format: .fixed(precision: 2), privacy: .public)s] settled by hash match at probe \(settledIndex + 1, privacy: .public)/\(probes.count, privacy: .public) (\(probes[settledIndex].time, format: .fixed(precision: 2), privacy: .public)s)")
            } else {
                Log.frames.debug("Pause window [\(window.startTime, format: .fixed(precision: 2), privacy: .public)s - \(window.endTime, format: .fixed(precision: 2), privacy: .public)s] never hash-settled — falling back to midpoint probe (\(probes[chosenIndex].time, format: .fixed(precision: 2), privacy: .public)s)")
            }

            let chosen = probes[chosenIndex]
            let originalPixelSize = "\(chosen.image.width)x\(chosen.image.height)"
            let frame: ExtractedShot = autoreleasepool {
                let image = PlatformImage.from(cgImage: chosen.image).downsized(maxDimension: maxFrameDimension)
                return ExtractedShot(timestamp: chosen.time, image: image)
            }
            Log.frames.debug("Chose frame at \(frame.timestamp, format: .fixed(precision: 2), privacy: .public)s (source \(originalPixelSize, privacy: .public), resized to \(frame.image.cgImage?.width ?? 0)x\(frame.image.cgImage?.height ?? 0))")
            frames.append(frame)
        }

        if decodeFailures > 0 {
            Log.frames.notice("\(decodeFailures, privacy: .public) probe frame(s) failed to decode")
        }

        Log.frames.info("Decoded \(frames.count, privacy: .public) settled frame(s), each capped at \(Int(self.maxFrameDimension), privacy: .public)px on the long edge")
        return frames.sorted { $0.timestamp < $1.timestamp }
    }
}
