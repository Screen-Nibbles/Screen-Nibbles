import Foundation
import CoreGraphics
import Vision
import Accelerate
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Protocol

@MainActor
public protocol ShotsToStitchesConverting: Sendable {
    func stitch(
        images: [PlatformImage],
        progress: @escaping (Double) -> Void
    ) async throws -> [PlatformImage]
}

public enum ShotsToStitchesError: LocalizedError {
    case compositingFailed
    case insufficientOverlap
    case missingImages
}

// MARK: - Helper Extensions

private extension CGImage {
    /// Crops using the top-left origin convention `cropping(to:)` already
    /// uses natively (y increasing downward), matching how the rest of this
    /// file reasons about rows. Note this is NOT the bottom-left/y-up
    /// convention `CGContext` uses for drawing — see `render(segments:...)`.
    func topLeftCropping(to rect: CGRect) -> CGImage? {
        cropping(to: rect)
    }

    /// Downscales an image for fast Vision processing without sacrificing final render quality.
    func downscaled(maxDimension: CGFloat) -> CGImage? {
        let maxDim = max(CGFloat(width), CGFloat(height))
        if maxDim <= maxDimension { return self }

        let scale = maxDimension / maxDim
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)

        guard let colorSpace = colorSpace,
              let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}

private extension PlatformImage {
    /// Cross-platform helper to initialize a platform image safely from a CGImage.
    static func create(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

// MARK: - Shots to Stitches Converter

@MainActor
public final class ShotsToStitchesConverter: ShotsToStitchesConverting {

    private let logger = Logger(subsystem: "com.tomaslin.Screen-Nibbles", category: "stitch")

    public init() {}

    public static func stitch(
        images: [PlatformImage],
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [PlatformImage] {
        let converter = ShotsToStitchesConverter()
        return try await converter.stitch(images: images, progress: progress)
    }

    public func stitch(
        images: [PlatformImage],
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [PlatformImage] {
        guard images.count > 1 else {
            progress(1.0)
            return images
        }

        logger.info("Starting optimized stitch for \(images.count) images")

        let allCGImages = images.compactMap { $0.cgImage }
        guard allCGImages.count == images.count else { throw ShotsToStitchesError.missingImages }
        guard allCGImages.count > 1 else {
            progress(1.0)
            return allCGImages.first.map { [PlatformImage.create(cgImage: $0)] } ?? []
        }

        let width = allCGImages[0].width
        let height = allCGImages[0].height

        let chrome = detectStaticChrome(in: allCGImages)
        logger.info("Dynamic Chrome Detected -> Top: \(chrome.top), Bottom: \(chrome.bottom)")

        let initialSafeHeight = height - chrome.top - chrome.bottom
        guard initialSafeHeight > 0 else { throw ShotsToStitchesError.insufficientOverlap }

        // `chrome.top` is derived from frame PAIRS (1...N), so it only proves
        // that region is static once scrolling is under way. Frame 0 has no
        // predecessor: if it was captured before any scrolling happened, that
        // same screen band shows live, unique page content rather than
        // pinned/fixed chrome, and blindly cropping `chrome.top` off it would
        // delete content that exists nowhere else in the sequence. Verify the
        // band is genuinely present in frame 0 by comparing it directly
        // against a later, presumably-settled frame, and only crop as far as
        // the two frames actually agree.
        let firstFrameChromeTop = verifiedFirstFrameChromeTop(
            firstFrame: allCGImages[0],
            referenceFrame: allCGImages[1],
            candidateTop: chrome.top
        )
        if firstFrameChromeTop != chrome.top {
            logger.info("First frame chrome unverified — using \(firstFrameChromeTop) instead of \(chrome.top) to avoid cropping unique content")
        }

        let firstSegmentHeight = height - firstFrameChromeTop - chrome.bottom
        guard firstSegmentHeight > 0 else { throw ShotsToStitchesError.insufficientOverlap }

        // Segments are accumulated in a running coordinate space that can grow
        // in EITHER direction: `topCursor` tracks the current top edge of the
        // stitched page, `bottomCursor` tracks the current bottom edge. A
        // downward scroll appends new content below `bottomCursor`; an upward
        // scroll prepends new content above `topCursor`. Everything is
        // normalized to a non-negative canvas at the end.
        var segments: [StitchSegment] = []
        segments.append(
            StitchSegment(
                image: allCGImages[0],
                cropRect: CGRect(x: 0, y: CGFloat(firstFrameChromeTop), width: CGFloat(width), height: CGFloat(firstSegmentHeight)),
                drawRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(firstSegmentHeight))
            )
        )

        var topCursor: CGFloat = 0
        var bottomCursor: CGFloat = CGFloat(firstSegmentHeight)
        let sequenceHandler = VNSequenceRequestHandler()

        for i in 1..<allCGImages.count {
            try autoreleasepool {
                let previousImg = allCGImages[i - 1]
                let currentImg = allCGImages[i]

                let contentRect = CGRect(x: 0, y: chrome.top, width: width, height: initialSafeHeight)

                guard let prevContent = previousImg.cropping(to: contentRect),
                      let currContent = currentImg.cropping(to: contentRect) else {
                    return
                }

                let scaleFactor: CGFloat
                let prevForVision: CGImage
                let currForVision: CGImage

                if let pv = prevContent.downscaled(maxDimension: 1024),
                   let cv = currContent.downscaled(maxDimension: 1024) {
                    scaleFactor = CGFloat(prevContent.width) / CGFloat(pv.width)
                    prevForVision = pv
                    currForVision = cv
                } else {
                    scaleFactor = 1.0
                    prevForVision = prevContent
                    currForVision = currContent
                }

                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currForVision)
                try? sequenceHandler.perform([request], on: prevForVision)

                // Preserve SIGN, not just magnitude, to tell up-scroll from
                // down-scroll. `alignmentTransform.ty` is negated here since
                // a positive `ty` corresponds to scrolling up, not down.
                var isFallback = false
                var signedEstimate = initialSafeHeight / 2
                if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                    let scaledTy = observation.alignmentTransform.ty * scaleFactor
                    signedEstimate = -Int(scaledTy.rounded())
                } else {
                    isFallback = true // no Vision result — fall back to downward
                }

                let scrolledDown = isFallback ? true : (signedEstimate >= 0)
                let estimatedMagnitude = abs(signedEstimate)

                let magnitude = refineAlignmentWithvDSP(
                    previous: prevContent,
                    current: currContent,
                    estimatedShift: estimatedMagnitude,
                    isFallback: isFallback
                )

                guard magnitude < initialSafeHeight else { return }

                // A near-zero magnitude doesn't necessarily mean "nothing
                // changed" — it means Vision/vDSP couldn't find a confident
                // *scroll* offset, which is exactly what happens when two
                // frames show the same viewport position but disagree in a
                // sub-region (a live element redrew, a modal appeared, etc).
                // Previously this was treated as a failed match and the
                // frame was dropped outright, silently discarding whatever
                // that later frame actually captured. Instead, treat it as a
                // same-position "replace": overlay this frame's full content
                // band on top of whatever's already drawn there so far, so
                // the later capture wins wherever the two disagree, rather
                // than being blended pixel-by-pixel or thrown away.
                guard magnitude > 5 else {
                    let overlapHeight = min(CGFloat(initialSafeHeight), bottomCursor - topCursor)
                    guard overlapHeight > 0 else { return }
                    let cropY = height - chrome.bottom - Int(overlapHeight)
                    let drawTop = bottomCursor - overlapHeight
                    segments.append(
                        StitchSegment(
                            image: currentImg,
                            cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: overlapHeight),
                            drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: overlapHeight)
                        )
                    )
                    return
                }
                let drawHeight = CGFloat(magnitude)

                if scrolledDown {
                    // New content revealed at the bottom of `currentImg`.
                    let cropY = height - chrome.bottom - magnitude
                    segments.append(
                        StitchSegment(
                            image: currentImg,
                            cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: drawHeight),
                            drawRect: CGRect(x: 0, y: bottomCursor, width: CGFloat(width), height: drawHeight)
                        )
                    )
                    bottomCursor += drawHeight
                } else {
                    // New content revealed at the top of `currentImg`.
                    let cropY = chrome.top
                    segments.append(
                        StitchSegment(
                            image: currentImg,
                            cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: drawHeight),
                            drawRect: CGRect(x: 0, y: topCursor - drawHeight, width: CGFloat(width), height: drawHeight)
                        )
                    )
                    topCursor -= drawHeight
                }
            }
            progress(Double(i) / Double(allCGImages.count))
        }

        if chrome.bottom > 0 {
            segments.append(
                StitchSegment(
                    image: allCGImages.last!,
                    cropRect: CGRect(x: 0, y: CGFloat(height - chrome.bottom), width: CGFloat(width), height: CGFloat(chrome.bottom)),
                    drawRect: CGRect(x: 0, y: bottomCursor, width: CGFloat(width), height: CGFloat(chrome.bottom))
                )
            )
            bottomCursor += CGFloat(chrome.bottom)
        }

        // Normalize: shift every segment so the topmost content sits at y=0.
        let originY = topCursor
        for idx in segments.indices {
            segments[idx].drawRect.origin.y -= originY
        }
        let totalHeight = Int((bottomCursor - originY).rounded())

        guard let finalCGImage = render(segments: segments, canvasWidth: width, canvasHeight: totalHeight) else {
            throw ShotsToStitchesError.compositingFailed
        }

        progress(1.0)
        return [PlatformImage.create(cgImage: finalCGImage)]
    }

    // MARK: - Core Types

    private struct Chrome { var top: Int; var bottom: Int }

    private struct StitchSegment {
        let image: CGImage
        var cropRect: CGRect
        var drawRect: CGRect
    }

    // MARK: - Dynamic Chrome Detection

    private func detectStaticChrome(in images: [CGImage]) -> Chrome {
        guard images.count > 1 else { return Chrome(top: 0, bottom: 0) }

        let height = images[0].height
        var tops: [Int] = []
        var bottoms: [Int] = []

        for i in 1..<images.count {
            let (top, bottom) = compareFrameChrome(frameA: images[i-1], frameB: images[i])
            if top == height { continue } // frames identical outright — uninformative, skip
            tops.append(top)
            bottoms.append(bottom)
        }

        guard !tops.isEmpty else { return Chrome(top: 0, bottom: 0) }

        // Median rather than min(): a single noisy or high-motion pair
        // shouldn't be able to zero out chrome for the whole stitch. Median
        // is robust to that single outlier while still reflecting the row
        // band the majority of pairs agree is static.
        return Chrome(top: median(of: tops), bottom: median(of: bottoms))
    }

    private func median(of values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Verifies how much of a globally-derived `candidateTop` chrome band is
    /// actually present in the first frame, rather than assuming it applies
    /// uniformly. `chrome.top` is measured from consecutive frame pairs
    /// (1...N), which only tells us that band is static *once scrolling has
    /// started* — it says nothing about frame 0, which may have been
    /// captured before any scroll occurred and therefore shows real page
    /// content in that same band instead of pinned chrome.
    ///
    /// True fixed chrome (an OS status bar, a pinned in-app header) is
    /// screen-locked, so if it's genuinely present in frame 0, its pixels
    /// should closely match the same rows in frame 1. If frame 0 instead
    /// shows unique unscrolled content there, the rows will disagree almost
    /// immediately. This deliberately compares only against the very next
    /// frame rather than a distant one: overlays like a screen-recording
    /// timer or a translucent status bar showing whatever page content sits
    /// behind it never stay byte-static over the full capture, so a distant
    /// frame would fail this check even where real chrome exists. Frame 1
    /// is the closest thing to "was this already-scrolled chrome at capture
    /// start", and failing to verify is the safe direction to fail in — at
    /// worst a sliver of true chrome survives on frame 0's own edge, which
    /// is far better than deleting content that exists nowhere else.
    private func verifiedFirstFrameChromeTop(
        firstFrame: CGImage,
        referenceFrame: CGImage,
        candidateTop: Int
    ) -> Int {
        guard candidateTop > 0 else { return 0 }
        guard firstFrame !== referenceFrame,
              let dataA = firstFrame.dataProvider?.data,
              let dataB = referenceFrame.dataProvider?.data,
              let ptrA = CFDataGetBytePtr(dataA),
              let ptrB = CFDataGetBytePtr(dataB) else {
            return candidateTop
        }

        let bytesPerRowA = firstFrame.bytesPerRow
        let bytesPerRowB = referenceFrame.bytesPerRow
        let bytesToCompare = min(firstFrame.width, referenceFrame.width) * (firstFrame.bitsPerPixel / 8)
        let rowTolerance: Int = 6 // same tolerance as compareFrameChrome, for consistency
        let rowCount = min(candidateTop, min(firstFrame.height, referenceFrame.height))

        func rowIsStatic(_ y: Int) -> Bool {
            let offsetA = y * bytesPerRowA
            let offsetB = y * bytesPerRowB
            var aFloats = [Float](repeating: 0, count: bytesToCompare)
            var bFloats = [Float](repeating: 0, count: bytesToCompare)
            vDSP_vfltu8(ptrA + offsetA, 1, &aFloats, 1, vDSP_Length(bytesToCompare))
            vDSP_vfltu8(ptrB + offsetB, 1, &bFloats, 1, vDSP_Length(bytesToCompare))
            var diffFloats = [Float](repeating: 0, count: bytesToCompare)
            vDSP_vsub(bFloats, 1, aFloats, 1, &diffFloats, 1, vDSP_Length(bytesToCompare))
            vDSP_vabs(diffFloats, 1, &diffFloats, 1, vDSP_Length(bytesToCompare))
            var total: Float = 0
            vDSP_sve(diffFloats, 1, &total, vDSP_Length(bytesToCompare))
            let mean = Double(total) / Double(bytesToCompare)
            return mean <= Double(rowTolerance)
        }

        var verifiedTop = 0
        for y in 0..<rowCount {
            if rowIsStatic(y) {
                verifiedTop += 1
            } else {
                break
            }
        }
        return verifiedTop
    }

    /// Row-tolerant chrome comparison. Frames decoded from a lossy video
    /// track (H.264/HEVC) are never byte-identical between frames even in
    /// genuinely static regions, since per-frame quantization noise touches
    /// every pixel. A row counts as "static" if its mean per-byte absolute
    /// difference is under a small tolerance.
    private func compareFrameChrome(frameA: CGImage, frameB: CGImage) -> (top: Int, bottom: Int) {
        guard let dataA = frameA.dataProvider?.data,
              let dataB = frameB.dataProvider?.data else { return (0, 0) }

        let ptrA = CFDataGetBytePtr(dataA)!
        let ptrB = CFDataGetBytePtr(dataB)!

        let height = frameA.height
        let bytesPerRow = frameA.bytesPerRow
        let bytesToCompare = frameA.width * (frameA.bitsPerPixel / 8)
        let rowTolerance: Int = 6 // mean per-byte |diff|; small enough to reject real content changes

        func rowIsStatic(_ y: Int) -> Bool {
            let offset = y * bytesPerRow
            var aFloats = [Float](repeating: 0, count: bytesToCompare)
            var bFloats = [Float](repeating: 0, count: bytesToCompare)
            vDSP_vfltu8(ptrA + offset, 1, &aFloats, 1, vDSP_Length(bytesToCompare))
            vDSP_vfltu8(ptrB + offset, 1, &bFloats, 1, vDSP_Length(bytesToCompare))
            var diffFloats = [Float](repeating: 0, count: bytesToCompare)
            vDSP_vsub(bFloats, 1, aFloats, 1, &diffFloats, 1, vDSP_Length(bytesToCompare))
            vDSP_vabs(diffFloats, 1, &diffFloats, 1, vDSP_Length(bytesToCompare))
            var total: Float = 0
            vDSP_sve(diffFloats, 1, &total, vDSP_Length(bytesToCompare))
            let mean = Double(total) / Double(bytesToCompare)
            return mean <= Double(rowTolerance)
        }

        var top = 0
        for y in 0..<height {
            if rowIsStatic(y) { top += 1 } else { break }
        }

        if top == height { return (height, height) }

        var bottom = 0
        for y in (0..<height).reversed() {
            if y <= top { break }
            if rowIsStatic(y) { bottom += 1 } else { break }
        }

        return (top, bottom)
    }

    // MARK: - Concurrent & Optimized vDSP Micro-Refinement

    /// Refines a coarse shift *magnitude* (direction-agnostic — see call site,
    /// which tracks direction separately from the signed Vision estimate).
    private func refineAlignmentWithvDSP(previous: CGImage, current: CGImage, estimatedShift: Int, isFallback: Bool) -> Int {
        guard let prevData = previous.dataProvider?.data,
              let currData = current.dataProvider?.data else { return estimatedShift }

        let prevPtr = CFDataGetBytePtr(prevData)!
        let currPtr = CFDataGetBytePtr(currData)!

        let width = previous.width
        let height = previous.height
        let bytesPerRow = previous.bytesPerRow
        let bytesPerPixel = previous.bitsPerPixel / 8

        let rowsToCompare = 20
        let totalFloats = width * bytesPerPixel * rowsToCompare

        let anchorYOffset = findFeatureRichSlice(ptr: currPtr, width: width, height: height, bytesPerRow: bytesPerRow, rows: rowsToCompare, bytesPerPixel: bytesPerPixel)

        let searchRadius = isFallback ? 250 : 15

        let startY = max(0, estimatedShift - searchRadius)
        let endY = min(height - rowsToCompare - anchorYOffset, estimatedShift + searchRadius)
        guard startY <= endY else { return estimatedShift }

        let shifts = Array(startY...endY)

        let lock = NSLock()
        var bestShift = estimatedShift
        var lowestDiff: Float = .greatestFiniteMagnitude

        let currOffset = anchorYOffset * bytesPerRow

        DispatchQueue.concurrentPerform(iterations: shifts.count) { index in
            let shift = shifts[index]
            var localPrevFloats = [Float](repeating: 0, count: totalFloats)
            var localCurrFloats = [Float](repeating: 0, count: totalFloats)
            var localDiffFloats = [Float](repeating: 0, count: totalFloats)

            let prevOffset = (shift + anchorYOffset) * bytesPerRow

            vDSP_vfltu8(prevPtr + prevOffset, 1, &localPrevFloats, 1, vDSP_Length(totalFloats))
            vDSP_vfltu8(currPtr + currOffset, 1, &localCurrFloats, 1, vDSP_Length(totalFloats))

            vDSP_vsub(localCurrFloats, 1, localPrevFloats, 1, &localDiffFloats, 1, vDSP_Length(totalFloats))
            vDSP_vabs(localDiffFloats, 1, &localDiffFloats, 1, vDSP_Length(totalFloats))

            var sum: Float = 0
            vDSP_sve(localDiffFloats, 1, &sum, vDSP_Length(totalFloats))

            lock.lock()
            if sum < lowestDiff {
                lowestDiff = sum
                bestShift = shift
            }
            lock.unlock()
        }

        return bestShift
    }

    private func findFeatureRichSlice(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, rows: Int, bytesPerPixel: Int) -> Int {
        let maxSearchDepth = min(height / 2, 200)
        let totalFloats = width * bytesPerPixel * rows
        var sliceFloats = [Float](repeating: 0, count: totalFloats)

        var bestY = 0
        var highestVariance: Float = 0

        for y in stride(from: 0, to: maxSearchDepth, by: 10) {
            let offset = y * bytesPerRow
            vDSP_vfltu8(ptr + offset, 1, &sliceFloats, 1, vDSP_Length(totalFloats))

            var mean: Float = 0
            var meanSquare: Float = 0

            vDSP_meanv(sliceFloats, 1, &mean, vDSP_Length(totalFloats))

            var squaredFloats = [Float](repeating: 0, count: totalFloats)
            vDSP_vsq(sliceFloats, 1, &squaredFloats, 1, vDSP_Length(totalFloats))
            vDSP_meanv(squaredFloats, 1, &meanSquare, vDSP_Length(totalFloats))

            let variance = meanSquare - (mean * mean)
            if variance > 500 { return y }

            if variance > highestVariance {
                highestVariance = variance
                bestY = y
            }
        }
        return bestY
    }

    // MARK: - Single-Pass Rendering Engine

    private func render(segments: [StitchSegment], canvasWidth: Int, canvasHeight: Int) -> CGImage? {
        guard let colorSpace = segments.first?.image.colorSpace else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // No context-level flip: `CGContext` defaults to bottom-left/y-up, so
        // each segment's top-left `drawRect` is converted into the context's
        // bottom-left space by hand, per segment, rather than flipping the CTM.
        for segment in segments {
            guard let cropped = segment.image.topLeftCropping(to: segment.cropRect) else { continue }
            let flippedY = CGFloat(canvasHeight) - segment.drawRect.maxY
            let drawRect = CGRect(x: segment.drawRect.minX, y: flippedY, width: segment.drawRect.width, height: segment.drawRect.height)
            context.draw(cropped, in: drawRect)
        }

        return context.makeImage()
    }
}
