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

        Log.frames.info("Extracting a frame for each of \(pauseWindows.count, privacy: .public) native pause window(s)")
        let frames = try await extractFrames(at: pauseWindows.map { $0.midpoint }, from: asset, progress: progress)
        return frames
    }

    /// Extracts decoded frames at specified timestamps and downsizes them to `maxFrameDimension`.
    private func extractFrames(
        at timestamps: [TimeInterval],
        from asset: AVURLAsset,
        progress: @escaping (Double) -> Void
    ) async throws -> [ExtractedShot] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxFrameDimension, height: maxFrameDimension)

        let times = timestamps.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [ExtractedShot] = []
        frames.reserveCapacity(times.count)

        var completed = 0
        var failed = 0

        for await result in generator.images(for: times) {
            completed += 1
            progress(Double(completed) / Double(times.count))

            guard case .success(let requestedTime, let cgImage, _) = result else {
                failed += 1
                Log.frames.notice("Frame \(completed, privacy: .public)/\(times.count, privacy: .public) at requested time failed to decode — skipping")
                continue
            }

            if FrameFilter.isIosControlCenter(cgImage) {
                Log.frames.notice("Frame \(completed, privacy: .public)/\(times.count, privacy: .public) at requested time is iOS Control Center — skipping")
                continue
            }

            let originalPixelSize = "\(cgImage.width)x\(cgImage.height)"
            let frame: ExtractedShot = autoreleasepool {
                let image = PlatformImage.from(cgImage: cgImage).downsized(maxDimension: maxFrameDimension)
                return ExtractedShot(timestamp: requestedTime.seconds, image: image)
            }

            Log.frames.debug("Frame \(completed, privacy: .public)/\(times.count, privacy: .public) decoded successfully at \(requestedTime.seconds, format: .fixed(precision: 2), privacy: .public)s (source \(originalPixelSize, privacy: .public), resized to \(frame.image.cgImage?.width ?? 0)x\(frame.image.cgImage?.height ?? 0))")
            frames.append(frame)
        }

        if failed > 0 {
            Log.frames.notice("\(failed, privacy: .public) of \(times.count, privacy: .public) requested frame(s) failed to decode")
        }

        Log.frames.info("Decoded \(frames.count, privacy: .public) frame(s), each capped at \(Int(self.maxFrameDimension), privacy: .public)px on the long edge")
        return frames.sorted { $0.timestamp < $1.timestamp }
    }
}
