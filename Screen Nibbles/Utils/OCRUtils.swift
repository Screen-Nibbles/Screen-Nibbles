import Foundation
import CoreGraphics
import Vision
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - OCR Result & Line Types

public struct OCRLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect // Normalized (0...1) Vision coordinates (origin bottom-left)

    public init(text: String, confidence: Float, boundingBox: CGRect = .zero) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct OCRResult: Sendable {
    public let fullText: String
    public let lines: [OCRLine]
    public let averageConfidence: Float
    public let detectedOrientation: CGImagePropertyOrientation

    public var wordCount: Int {
        fullText.split(whereSeparator: \.isWhitespace).count
    }

    public static let empty = OCRResult(
        fullText: "",
        lines: [],
        averageConfidence: 0,
        detectedOrientation: .up
    )

    public init(
        fullText: String,
        lines: [OCRLine],
        averageConfidence: Float,
        detectedOrientation: CGImagePropertyOrientation = .up
    ) {
        self.fullText = fullText
        self.lines = lines
        self.averageConfidence = averageConfidence
        self.detectedOrientation = detectedOrientation
    }
}

public struct OCRFilterOptions: Sendable {
    public var minimumConfidence: Float
    public var filterMenusAndButtons: Bool
    public var filterDatesAndTimes: Bool
    public var deduplicateRepeatedLines: Bool
    public var autoRotate: Bool

    public nonisolated static let standard = OCRFilterOptions(
        minimumConfidence: 0.35,
        filterMenusAndButtons: true,
        filterDatesAndTimes: true,
        deduplicateRepeatedLines: true,
        autoRotate: true
    )

    public init(
        minimumConfidence: Float = 0.35,
        filterMenusAndButtons: Bool = true,
        filterDatesAndTimes: Bool = true,
        deduplicateRepeatedLines: Bool = true,
        autoRotate: Bool = true
    ) {
        self.minimumConfidence = minimumConfidence
        self.filterMenusAndButtons = filterMenusAndButtons
        self.filterDatesAndTimes = filterDatesAndTimes
        self.deduplicateRepeatedLines = deduplicateRepeatedLines
        self.autoRotate = autoRotate
    }
}

// MARK: - OCR Utils Engine

/// Optical Character Recognition engine for extracting and deduplicating text from stitches and screenshots
/// using Apple's Vision framework (`VNRecognizeTextRequest`) with autorotation, Live Text support, and redaction intelligence.
public enum OCRUtils {

    /// Known static UI chrome and navigation labels to filter out during clean scans.
    private static let chromeKeywords: Set<String> = [
        "home", "search", "explore", "notifications", "messages", "profile",
        "settings", "following", "for you", "share", "save", "saved", "like",
        "comment", "repost", "cancel", "done", "back", "edit", "more", "menu"
    ]

    /// Date & timestamp regex patterns.
    private static let timestampPatterns: [String] = [
        #"^\d{1,2}:\d{2}(\s?[APap][Mm])?$"#,
        #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#,
        #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\s+\d{1,2}"#,
        #"^\d+\s+(min|mins|minute|minutes|hr|hrs|hour|hours|d|day|days|w|week|weeks)\s+ago$"#
    ]

    // MARK: - Public Extraction API

    /// Extracts text from a `PlatformImage` asynchronously with autorotation.
    public static func extractText(
        from image: PlatformImage,
        options: OCRFilterOptions = .standard
    ) async throws -> OCRResult {
        guard let cgImage = image.cgImage else {
            return .empty
        }
        return try await extractText(from: cgImage, options: options)
    }

    /// Extracts text from raw image `Data` asynchronously with autorotation.
    public static func extractText(
        from data: Data,
        options: OCRFilterOptions = .standard
    ) async throws -> OCRResult {
        guard let platformImage = PlatformImage(data: data),
              let cgImage = platformImage.cgImage else {
            return .empty
        }
        return try await extractText(from: cgImage, options: options)
    }

    /// Extracts text from a `CGImage` asynchronously using Apple Vision, with automatic orientation detection.
    public static func extractText(
        from cgImage: CGImage,
        options: OCRFilterOptions = .standard
    ) async throws -> OCRResult {
        if options.autoRotate {
            // First attempt with default orientation
            let defaultResult = try await performVisionRequest(on: cgImage, orientation: .up, options: options)
            if defaultResult.lines.count > 0 && defaultResult.averageConfidence >= 0.5 {
                return defaultResult
            }

            // If confidence is low or no text detected, test rotated orientations (e.g. landscape or upside down)
            let testOrientations: [CGImagePropertyOrientation] = [.right, .left, .down]
            var bestResult = defaultResult

            for orientation in testOrientations {
                if let rotatedResult = try? await performVisionRequest(on: cgImage, orientation: orientation, options: options) {
                    if rotatedResult.lines.count > bestResult.lines.count && rotatedResult.averageConfidence > bestResult.averageConfidence {
                        bestResult = rotatedResult
                    }
                }
            }

            return bestResult
        } else {
            return try await performVisionRequest(on: cgImage, orientation: .up, options: options)
        }
    }

    private static func performVisionRequest(
        on cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        options: OCRFilterOptions
    ) async throws -> OCRResult {
        return try await withCheckedThrowingContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    Log.stitch.error("OCR recognition error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: .empty)
                    return
                }

                let processedResult = processObservations(observations, orientation: orientation, options: options)
                continuation.resume(returning: processedResult)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "en-GB", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-Hans"]

            do {
                try requestHandler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Post-Processing & Filtering

    private static func processObservations(
        _ observations: [VNRecognizedTextObservation],
        orientation: CGImagePropertyOrientation,
        options: OCRFilterOptions
    ) -> OCRResult {
        var rawLines: [OCRLine] = []
        var totalConfidence: Float = 0
        var validObservationsCount = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let confidence = candidate.confidence
            guard confidence >= options.minimumConfidence else { continue }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let bbox = observation.boundingBox
            rawLines.append(OCRLine(text: text, confidence: confidence, boundingBox: bbox))
            totalConfidence += confidence
            validObservationsCount += 1
        }

        guard !rawLines.isEmpty else { return .empty }

        var filteredLines: [OCRLine] = []
        var seenNormalizedLines = Set<String>()

        for line in rawLines {
            let text = line.text

            if options.filterMenusAndButtons && isMenuOrChrome(text) {
                continue
            }

            if options.filterDatesAndTimes && isTimestamp(text) {
                continue
            }

            if options.deduplicateRepeatedLines {
                let normalized = normalizeText(text)
                if normalized.count > 3 && seenNormalizedLines.contains(normalized) {
                    continue
                }
                seenNormalizedLines.insert(normalized)
            }

            filteredLines.append(line)
        }

        let fullText = filteredLines.map(\.text).joined(separator: "\n")
        let avgConfidence = validObservationsCount > 0 ? (totalConfidence / Float(validObservationsCount)) : 0

        return OCRResult(
            fullText: fullText,
            lines: filteredLines,
            averageConfidence: avgConfidence,
            detectedOrientation: orientation
        )
    }

    public static func isMenuOrChrome(_ text: String) -> Bool {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if chromeKeywords.contains(clean) {
            return true
        }
        if clean.count <= 3 && (clean.contains("<") || clean.contains(">") || clean.contains("•") || clean.contains(".")) {
            return true
        }
        return false
    }

    public static func isTimestamp(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in timestampPatterns {
            if clean.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    public static func normalizeText(_ text: String) -> String {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
