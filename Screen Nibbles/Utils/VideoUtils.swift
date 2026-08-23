import SwiftUI
import CoreGraphics
import CoreVideo
import ImageIO
import AVFoundation
import CoreImage
import Foundation
import os


// MARK: - Frame Filter

public struct FrameFilter {
    /// Diagnostic per-row metrics from the Control Center heuristic, exposed so real
    /// Core Graphics resize output can be inspected directly instead of estimated.
    public struct RowMetrics {
        public let row: Int
        public let s1Var: Double
        public let s2Var: Double
        public let contrastGap1: Double
        public let contrastGap2: Double
        public let contrastLeft: Double
        public let contrastRight: Double
    }

    /// Computes the raw per-row metrics used by `isIosControlCenter`, without applying
    /// the pass/fail thresholds. Returns `nil` if the aspect-ratio gate fails.
    public static func controlCenterRowMetrics(_ image: CGImage) -> [RowMetrics]? {
        let w = image.width
        let h = image.height

        if w >= h || Double(h) / Double(w) < 1.7 {
            return nil
        }

        let targetSize = 100
        guard let context = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: targetSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: targetSize * targetSize * 4)

        func getLum(x: Int, y: Int) -> Double {
            let idx = (y * targetSize + x) * 4
            let r = Double(buffer[idx])
            let g = Double(buffer[idx + 1])
            let b = Double(buffer[idx + 2])
            return 0.299 * r + 0.587 * g + 0.114 * b
        }

        var results: [RowMetrics] = []
        for y in [38, 40, 42] {
            var s1Var: Double = 0
            for x in 56...64 {
                s1Var = max(s1Var, abs(getLum(x: x, y: y) - getLum(x: x - 1, y: y)))
            }

            var s2Var: Double = 0
            for x in 76...84 {
                s2Var = max(s2Var, abs(getLum(x: x, y: y) - getLum(x: x - 1, y: y)))
            }

            let lumS1 = getLum(x: 60, y: y)
            let lumGap = getLum(x: 70, y: y)
            let lumS2 = getLum(x: 80, y: y)
            let lumLeft = getLum(x: 50, y: y)
            let lumRight = getLum(x: 90, y: y)

            results.append(RowMetrics(
                row: y,
                s1Var: s1Var,
                s2Var: s2Var,
                contrastGap1: abs(lumS1 - lumGap),
                contrastGap2: abs(lumS2 - lumGap),
                contrastLeft: abs(lumS1 - lumLeft),
                contrastRight: abs(lumS2 - lumRight)
            ))
        }
        return results
    }

    /// Detects whether an image represents the iOS Control Center overlay.
    ///
    /// - Parameter image: The `CGImage` to evaluate.
    /// - Returns: `true` if the image resembles the Control Center, `false` otherwise.
    public static func isIosControlCenter(_ image: CGImage) -> Bool {
        guard let rows = controlCenterRowMetrics(image) else { return false }

        var validRows = 0
        for m in rows {
            if m.s1Var < 8 && m.s2Var < 8 && m.contrastGap1 > 15 && m.contrastGap2 > 15
                && (m.contrastLeft > 12 || m.contrastRight > 12) {
                validRows += 1
            }
        }

        return validRows >= 2
    }
}

// MARK: - Video Frame Timing & Pause Analyzer

/// Looks for pauses in a video by reading its encoded frame timing.
public final class VideoFrameAnalyzer {
    private let pauseGapMultiplier = 2.5
    private let minimumPauseCount = 2
    private let clusterGapThreshold: TimeInterval = 0.15
    private let minimumPauseDuration: TimeInterval = 0.25

    /// A stretch of time where the encoded video held on a single frame.
    public struct PauseWindow {
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public var midpoint: TimeInterval { (startTime + endTime) / 2 }
    }

    public init() {}

    /// Scans an asset's actual sample timestamps for variable-frame-rate pauses.
    public func detectPauses(in asset: AVURLAsset) async throws -> [PauseWindow]? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            Log.frames.notice("No video track on asset — can't analyze frame timing")
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            Log.frames.notice("Asset reader couldn't add a track output — can't analyze frame timing")
            return nil
        }
        reader.add(output)
        reader.startReading()

        var timestamps: [TimeInterval] = []
        while let sampleBuffer = reader.status == .reading ? output.copyNextSampleBuffer() : nil {
            let pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            if pts.isValid {
                timestamps.append(pts.seconds)
            }
        }
        reader.cancelReading()

        Log.frames.info("Read \(timestamps.count, privacy: .public) sample timestamp(s) from the video track")

        guard timestamps.count > 4 else {
            Log.frames.notice("Only \(timestamps.count, privacy: .public) sample(s) — too few to judge frame timing")
            return nil
        }
        timestamps.sort()

        let gaps = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        guard !gaps.isEmpty else {
            Log.frames.notice("No gaps between samples — can't judge frame timing")
            return nil
        }

        let nominalDuration = gaps.sorted()[gaps.count / 2]
        guard nominalDuration > 0 else {
            Log.frames.notice("Nominal frame duration computed as zero — can't judge frame timing")
            return nil
        }

        let pauseGapThreshold = nominalDuration * pauseGapMultiplier
        Log.frames.info("Nominal frame gap ~\(nominalDuration, format: .fixed(precision: 4), privacy: .public)s; pause threshold ~\(pauseGapThreshold, format: .fixed(precision: 4), privacy: .public)s")

        var rawWindows: [PauseWindow] = []
        for (index, gap) in gaps.enumerated() where gap >= pauseGapThreshold {
            let window = PauseWindow(startTime: timestamps[index], endTime: timestamps[index + 1])
            rawWindows.append(window)
            Log.frames.debug("Detected pause gap: \(gap, format: .fixed(precision: 4))s at [\(window.startTime, format: .fixed(precision: 2))s - \(window.endTime, format: .fixed(precision: 2))s] (midpoint: \(window.midpoint, format: .fixed(precision: 2))s)")
        }

        Log.frames.info("Found \(rawWindows.count, privacy: .public) candidate pause window(s) (need at least \(self.minimumPauseCount, privacy: .public))")

        guard rawWindows.count >= minimumPauseCount else {
            Log.frames.notice("Not enough pause windows — treating this video as not variable-frame-rate")
            return nil
        }

        let clustered = collapseClusters(rawWindows)
        let windows = clustered.filter { $0.endTime - $0.startTime >= minimumPauseDuration }
        let droppedShort = clustered.count - windows.count
        if droppedShort > 0 {
            Log.frames.info("Dropped \(droppedShort, privacy: .public) pause window(s) under \(self.minimumPauseDuration, format: .fixed(precision: 2))s after clustering")
        }

        guard windows.count >= minimumPauseCount else {
            Log.frames.notice("Not enough pause windows survived clustering/duration filtering — treating this video as not variable-frame-rate")
            return nil
        }

        Log.frames.info("Video timing looks variable-frame-rate — using its \(windows.count, privacy: .public) pause window(s) directly")
        return windows
    }

    private func collapseClusters(_ windows: [PauseWindow]) -> [PauseWindow] {
        guard var current = windows.first else { return [] }
        var result: [PauseWindow] = []

        for window in windows.dropFirst() {
            let gapToNext = window.startTime - current.endTime
            if gapToNext < clusterGapThreshold {
                current = PauseWindow(startTime: current.startTime, endTime: max(current.endTime, window.endTime))
            } else {
                result.append(current)
                current = window
            }
        }
        result.append(current)
        return result
    }
}
