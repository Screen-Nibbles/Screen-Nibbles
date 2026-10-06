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

    public var errorDescription: String? {
        switch self {
        case .compositingFailed: return "Could not render the stitched image. Try a shorter recording."
        case .insufficientOverlap: return "The frames do not have enough visible content to stitch."
        case .missingImages: return "One of the captured images could not be read."
        }
    }
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

        var allCGImages = images.compactMap { $0.cgImage.flatMap { normalized($0) } }
        let unreadableCount = images.count - allCGImages.count
        if unreadableCount > 0 {
            logger.notice("Skipping \(unreadableCount, privacy: .public) unreadable/incomplete frame(s) instead of failing the whole capture")
        }
        guard !allCGImages.isEmpty else { throw ShotsToStitchesError.missingImages }

        // A decoder can occasionally emit one frame at a bogus intermediate
        // size while a screen recording changes surfaces. If the frames on
        // both sides agree on dimensions, that isolated size is noise, not a
        // real orientation change.
        if allCGImages.count >= 3 {
            var isolatedDimensionOutliers = Set<Int>()
            for index in 1..<(allCGImages.count - 1) {
                let previous = allCGImages[index - 1]
                let current = allCGImages[index]
                let next = allCGImages[index + 1]
                let neighborsAgree = previous.width == next.width && previous.height == next.height
                let currentDiffers = current.width != previous.width || current.height != previous.height
                if neighborsAgree && currentDiffers { isolatedDimensionOutliers.insert(index) }
            }
            if !isolatedDimensionOutliers.isEmpty {
                logger.notice("Skipping \(isolatedDimensionOutliers.count, privacy: .public) isolated dimension-outlier frame(s)")
                allCGImages = allCGImages.enumerated().compactMap { index, image in
                    isolatedDimensionOutliers.contains(index) ? nil : image
                }
            }
        }

        guard allCGImages.count > 1 else {
            progress(1.0)
            return allCGImages.first.map { [PlatformImage.create(cgImage: $0)] } ?? []
        }

        let width = allCGImages[0].width
        let height = allCGImages[0].height
        guard allCGImages.allSatisfy({ $0.width == width && $0.height == height }) else {
            // Orientation changes are independent captures, never crop them to the first frame.
            var groups: [[PlatformImage]] = []
            for image in allCGImages {
                if let last = groups.last?.last?.cgImage, last.width == image.width && last.height == image.height {
                    groups[groups.count - 1].append(.create(cgImage: image))
                } else { groups.append([.create(cgImage: image)]) }
            }
            var results: [PlatformImage] = []
            for group in groups {
                try Task.checkCancellation()
                results += try await stitch(images: group, progress: { _ in })
            }
            progress(1)
            return results
        }

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

        // ------------------------------------------------------------------
        // PASS 1 — Complete potential-stitching evaluation.
        //
        // Every consecutive pair is measured and classified BEFORE anything
        // is stitched, so plan decisions are made with knowledge of the
        // whole sequence instead of incrementally. Each entry is the
        // transition INTO frame `i` (frame 0 has none). A nil entry means
        // the pair couldn't even be measured (decode/crop failure); frame i
        // is skipped by planning, matching the historic silent-skip
        // behavior.
        // ------------------------------------------------------------------
        var transitions: [SpanDirection?] = Array(repeating: nil, count: allCGImages.count)
        let sequenceHandler = VNSequenceRequestHandler()

        for i in 1..<allCGImages.count {
            try Task.checkCancellation()
            await Task.yield()
            transitions[i] = autoreleasepool {
                measureTransition(
                    previousImg: allCGImages[i - 1],
                    currentImg: allCGImages[i],
                    chrome: chrome,
                    width: width,
                    height: height,
                    sequenceHandler: sequenceHandler
                )
            }
            progress(Double(i) / Double(allCGImages.count) * 0.95)
        }

        // A single torn/half-decoded frame used to split an otherwise clean
        // scroll twice: good -> bad and bad -> good. When both adjacent
        // transitions are unusable but the frames on either side register
        // cleanly, drop only that transient frame and re-plan the sequence.
        // This also handles one-frame overlays caused by capture hand-off.
        var transientIndices = Set<Int>()
        if allCGImages.count >= 3 {
            var start = 1
            while start < allCGImages.count - 1 {
                guard isBrokenTransition(transitions[start]) else {
                    start += 1
                    continue
                }

                var recoveredAt: Int?
                let furthestCandidate = min(allCGImages.count - 1, start + 3)
                if start + 1 <= furthestCandidate {
                    for candidate in (start + 1)...furthestCandidate {
                        // Every transition through the suspect run must be bad;
                        // otherwise we're looking at a real new shot, not damage.
                        guard (start...candidate).allSatisfy({ isBrokenTransition(transitions[$0]) }) else { break }
                        let bridge = autoreleasepool {
                            measureTransition(
                                previousImg: allCGImages[start - 1],
                                currentImg: allCGImages[candidate],
                                chrome: chrome,
                                width: width,
                                height: height,
                                sequenceHandler: VNSequenceRequestHandler()
                            )
                        }
                        if !isBrokenTransition(bridge) {
                            for index in start..<candidate { transientIndices.insert(index) }
                            recoveredAt = candidate
                            break
                        }
                    }
                }

                start = (recoveredAt ?? start) + 1
            }
        }

        if !transientIndices.isEmpty {
            logger.notice("Recovering from \(transientIndices.count, privacy: .public) transient/incomplete middle frame(s)")
            let repaired = allCGImages.enumerated().compactMap { index, image in
                transientIndices.contains(index) ? nil : PlatformImage.create(cgImage: image)
            }
            return try await stitch(images: repaired) { repairedProgress in
                // The expensive diagnosis already reached the end of pass 1;
                // never make the UI progress bar jump backwards during retry.
                progress(max(0.95, repairedProgress))
            }
        }

        // ------------------------------------------------------------------
        // PASS 2 — Greedy plan-and-render.
        //
        // With every transition already known, this walk makes only plan
        // decisions (which frames survive, where they land) and defers all
        // rendering until each group closes. Frames superseded by a later
        // same-position capture (.replace) are DISCARDED here — removed
        // from the plan rather than drawn and painted over. Segments draw
        // in append order, which is video order, so wherever two surviving
        // frames overlap on the canvas the LATEST frame's look wins: the
        // stitch always grabs the newest appearance while keeping the
        // page laid out in capture sequence.
        // ------------------------------------------------------------------

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
        var supersededFrameCount = 0
        var currentY: CGFloat = CGFloat(chrome.top - firstFrameChromeTop)
        var horizontalSegments: [StitchSegment] = []
        var currentX: CGFloat = 0

        func flushHorizontal() {
            guard !horizontalSegments.isEmpty else { return }
            let minX = horizontalSegments.map(\.drawRect.minX).min() ?? 0
            let maxX = horizontalSegments.map(\.drawRect.maxX).max() ?? CGFloat(width)
            for index in horizontalSegments.indices { horizontalSegments[index].drawRect.origin.x -= minX }
            if let result = render(segments: horizontalSegments, canvasWidth: Int(maxX - minX), canvasHeight: initialSafeHeight) {
                finishedResults.append(.create(cgImage: result))
            } else { renderFailed = true }
            horizontalSegments = []
            currentX = 0
        }

        // A capture can contain more than one distinct "shot": a vertical
        // scroll can be interrupted by a horizontal carousel swipe, or by a
        // jump too large/unrelated to explain as either. `finishedResults`
        // collects every fully-resolved group (carousel strips, and vertical
        // panoramas that got cut short by a mismatch) as the loop goes;
        // `segments`/`topCursor`/`bottomCursor` always describe the vertical
        // group that's still open.
        var finishedResults: [PlatformImage] = []
        var renderFailed = false

        // Carousel accumulation state for the currently in-progress
        // horizontal run, if any. `carouselBandRows` is fixed by the FIRST
        // pair detected as a carousel in a run, so every card in the strip
        // is cropped to the same rows and lines up cleanly side by side.
        var carouselSegments: [StitchSegment] = []
        var carouselBandRows: (top: Int, bottom: Int)?
        var carouselCanvasWidth: CGFloat = 0

        // True while the open vertical group contains nothing but its
        // original seed frame *and* that same seed frame has also been used
        // to anchor a carousel strip. If the group never grows past that
        // seed, emitting it standalone would just duplicate the carousel's
        // first card, so it gets suppressed instead — the seed frame is
        // still represented, just via the carousel.
        var verticalSeedIsRedundant = false

        func flushCarousel() {
            guard !carouselSegments.isEmpty, let bandRows = carouselBandRows else { return }
            let canvasHeight = bandRows.bottom - bandRows.top
            if canvasHeight > 0,
               let stripImage = render(segments: carouselSegments, canvasWidth: Int(carouselCanvasWidth), canvasHeight: canvasHeight) {
                finishedResults.append(PlatformImage.create(cgImage: stripImage))
            } else { renderFailed = true }
            carouselSegments = []
            carouselBandRows = nil
            carouselCanvasWidth = 0
        }

        func appendCarouselFrame(previous: CGImage, current: CGImage, bandTop: Int, bandBottomExclusive: Int) {
            let bandHeight = bandBottomExclusive - bandTop
            guard bandHeight > 0 else { return }

            if carouselSegments.isEmpty {
                // Seed the strip with the ANCHOR frame's own card. That
                // anchor is exactly whatever the open vertical group's most
                // recent segment already is, so the first carousel card
                // stays visible in the vertical scroll too, not just here.
                carouselBandRows = (top: bandTop, bottom: bandBottomExclusive)
                carouselSegments.append(
                    StitchSegment(
                        image: previous,
                        cropRect: CGRect(x: 0, y: CGFloat(bandTop), width: CGFloat(width), height: CGFloat(bandHeight)),
                        drawRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(bandHeight))
                    )
                )
                carouselCanvasWidth = CGFloat(width)

                if segments.count == 1 {
                    verticalSeedIsRedundant = true
                }
            }

            guard let fixedBand = carouselBandRows else { return }
            let fixedHeight = fixedBand.bottom - fixedBand.top
            carouselSegments.append(
                StitchSegment(
                    image: current,
                    cropRect: CGRect(x: 0, y: CGFloat(fixedBand.top), width: CGFloat(width), height: CGFloat(fixedHeight)),
                    drawRect: CGRect(x: carouselCanvasWidth, y: 0, width: CGFloat(width), height: CGFloat(fixedHeight))
                )
            )
            carouselCanvasWidth += CGFloat(width)
        }

        func flushVerticalGroup() {
            defer {
                segments = []
                topCursor = 0
                bottomCursor = 0
                verticalSeedIsRedundant = false
                currentY = 0
            }
            // The bottom chrome strip must come from the group's last
            // SURVIVING frame — earlier ones may have been pruned by
            // `.replace`, and a superseded frame's stale chrome pixels are
            // exactly what this pass exists to throw away.
            guard let lastAliveImage = segments.last?.image else { return }

            if segments.count == 1 && verticalSeedIsRedundant {
                // Nothing but the shared seed frame — already preserved as
                // the carousel's first card. Skip emitting a duplicate.
                return
            }

            if chrome.bottom > 0 {
                segments.append(
                    StitchSegment(
                        image: lastAliveImage,
                        cropRect: CGRect(x: 0, y: CGFloat(height - chrome.bottom), width: CGFloat(width), height: CGFloat(chrome.bottom)),
                        drawRect: CGRect(x: 0, y: bottomCursor, width: CGFloat(width), height: CGFloat(chrome.bottom))
                    )
                )
                bottomCursor += CGFloat(chrome.bottom)
            }

            let originY = topCursor
            for idx in segments.indices {
                segments[idx].drawRect.origin.y -= originY
            }
            let totalHeight = Int((bottomCursor - originY).rounded())
            guard totalHeight > 0,
                  let image = render(segments: segments, canvasWidth: width, canvasHeight: totalHeight) else { renderFailed = true; return }
            finishedResults.append(PlatformImage.create(cgImage: image))
        }

        func startNewVerticalGroup(anchor: CGImage) {
            segments = [
                StitchSegment(
                    image: anchor,
                    cropRect: CGRect(x: 0, y: CGFloat(chrome.top), width: CGFloat(width), height: CGFloat(initialSafeHeight)),
                    drawRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(initialSafeHeight))
                )
            ]
            topCursor = 0
            bottomCursor = CGFloat(initialSafeHeight)
            verticalSeedIsRedundant = false
            currentY = 0
        }

        for i in 1..<allCGImages.count {
            // nil = pair i couldn't be measured in pass 1; frame i is
            // skipped entirely, exactly like the old silent crop-failure skip.
            guard let direction = transitions[i] else { continue }

            let previousImg = allCGImages[i - 1]
            let currentImg = allCGImages[i]

            switch direction {
            case .horizontalScroll(let shift, let right):
                flushCarousel()
                if horizontalSegments.isEmpty {
                    if segments.count == 1 { segments = [] }
                    else { flushVerticalGroup() }
                    horizontalSegments = [StitchSegment(image: previousImg,
                        cropRect: CGRect(x: 0, y: chrome.top, width: width, height: initialSafeHeight),
                        drawRect: CGRect(x: 0, y: 0, width: width, height: initialSafeHeight))]
                }
                currentX += CGFloat(right ? shift : -shift)
                horizontalSegments.append(StitchSegment(image: currentImg,
                    cropRect: CGRect(x: 0, y: chrome.top, width: width, height: initialSafeHeight),
                    drawRect: CGRect(x: currentX, y: 0, width: CGFloat(width), height: CGFloat(initialSafeHeight))))

            case .verticalScroll(let shift, let scrolledDown):
                if !horizontalSegments.isEmpty {
                    flushHorizontal()
                    startNewVerticalGroup(anchor: previousImg)
                }
                flushCarousel()
                // Place frames relative to the previous viewport, so reversals revisit existing content.
                let drawHeight = CGFloat(shift)

                // Redraw the CURRENT frame's *entire* visible content
                // band — not just the sliver of new content the shift
                // revealed — positioned so its already-seen portion
                // lands exactly back on top of whatever the previous
                // frame(s) already drew there. `render(segments:...)`
                // draws segments in append (video) order, so this later
                // frame's pixels always win over the earlier frames'
                // pixels in any shared band. Without this, a floating/
                // transient element (e.g. a nav pill) that happened to
                // render into an earlier frame but not the current one
                // would stick around, and vice versa.
                if scrolledDown {
                    // Bottom edge of the full band already lines up with
                    // this frame's own bottom (minus chrome); its top
                    // now reaches up into the previously-drawn overlap.
                    // (`height - chrome.bottom - initialSafeHeight == chrome.top`.)
                    currentY += drawHeight
                    let drawTop = currentY
                    segments.append(
                        StitchSegment(
                            image: currentImg,
                            cropRect: CGRect(x: 0, y: CGFloat(chrome.top), width: CGFloat(width), height: CGFloat(initialSafeHeight)),
                            drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: CGFloat(initialSafeHeight))
                        )
                    )
                    bottomCursor = max(bottomCursor, drawTop + CGFloat(initialSafeHeight))
                } else {
                    // Top edge of the full band already lines up with
                    // this frame's own top (plus chrome); its bottom now
                    // reaches down into the previously-drawn overlap.
                    let cropY = chrome.top
                    currentY -= drawHeight
                    let drawTop = currentY
                    segments.append(
                        StitchSegment(
                            image: currentImg,
                            cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: CGFloat(initialSafeHeight)),
                            drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: CGFloat(initialSafeHeight))
                        )
                    )
                    topCursor = min(topCursor, drawTop)
                }

            case .horizontalCarousel(let bandTop, let bandBottomExclusive):
                if !horizontalSegments.isEmpty {
                    flushHorizontal()
                    startNewVerticalGroup(anchor: previousImg)
                }
                // Same viewport position, but a bounded band swapped
                // horizontally (a carousel swipe) rather than the small,
                // page-wide disagreement `.replace` handles. Keep it out
                // of the vertical stitch entirely and build/extend a
                // separate side-by-side strip instead. The vertical
                // group's most recent surviving segment becomes the
                // strip's first card, so that frame stays part of the
                // vertical scroll too.
                appendCarouselFrame(previous: previousImg, current: currentImg, bandTop: bandTop, bandBottomExclusive: bandBottomExclusive)
                if let last = segments.popLast() {
                    segments.append(StitchSegment(image: currentImg, cropRect: last.cropRect, drawRect: last.drawRect))
                }

            case .replace:
                flushCarousel()
                // Update the last viewport at its existing position without increasing the canvas.
                if !horizontalSegments.isEmpty {
                    if let last = horizontalSegments.popLast() {
                        horizontalSegments.append(StitchSegment(image: currentImg, cropRect: last.cropRect, drawRect: last.drawRect))
                    }
                } else if let last = segments.popLast() {
                    supersededFrameCount += 1
                    // Preserve the last viewport's actual position, including upward scrolls.
                    segments.append(StitchSegment(image: currentImg, cropRect: last.cropRect, drawRect: last.drawRect))
                }

            case .mismatch:
                flushHorizontal()
                // Neither a vertical scroll nor a bounded carousel band
                // explains this transition — too different to be the
                // same shot. Close out whatever's open and start clean.
                flushCarousel()
                flushVerticalGroup()
                startNewVerticalGroup(anchor: currentImg)
            }
        }

        flushHorizontal()
        flushCarousel()
        flushVerticalGroup()

        logger.info("Stitch plan complete: \(supersededFrameCount) superseded frame(s) discarded, \(finishedResults.count) output group(s)")

        guard !renderFailed, !finishedResults.isEmpty else {
            throw ShotsToStitchesError.compositingFailed
        }

        progress(1.0)
        return finishedResults
    }

    // MARK: - Frame-Transition Classification

    /// What relationship, if any, connects two consecutive frames.
    ///
    /// Instances are computed for EVERY consecutive pair up front (pass 1 of
    /// the stitcher) and consumed later by the plan builder (pass 2), so the
    /// payload has to be self-contained — nothing about the measuring loop's
    /// local state survives into planning.
    private enum SpanDirection: Equatable {
        /// The page scrolled by `shift` px; `scrolledDown` says whether the
        /// open vertical group grows below its bottom cursor or above its
        /// top cursor.
        case verticalScroll(shift: Int, scrolledDown: Bool)
        case horizontalScroll(shift: Int, right: Bool)
        /// Same scroll position, but a bounded row band swapped out (a
        /// carousel swipe). `top`/`bottom` are the rows (in the ORIGINAL,
        /// uncropped frame) that changed and should be split into their own
        /// side-by-side strip.
        case horizontalCarousel(top: Int, bottom: Int)
        /// Same scroll position, no bounded band — a small in-place content
        /// change (e.g. a live widget re-rendering). The newer frame
        /// supersedes (prunes) the group's most recent frame.
        case replace
        /// Too different to explain as any of the above; starts a new shot.
        case mismatch
    }

    private func isBrokenTransition(_ direction: SpanDirection?) -> Bool {
        guard let direction else { return true }
        if case .mismatch = direction { return true }
        return false
    }

    /// Measures one pair without mutating stitch state. Keeping registration in
    /// one place makes it possible to probe across a suspicious middle frame
    /// and recover when that frame is torn or only partially decoded.
    private func measureTransition(
        previousImg: CGImage,
        currentImg: CGImage,
        chrome: Chrome,
        width: Int,
        height: Int,
        sequenceHandler: VNSequenceRequestHandler
    ) -> SpanDirection? {
        let safeHeight = height - chrome.top - chrome.bottom
        guard safeHeight > 0 else { return nil }
        let contentRect = CGRect(x: 0, y: chrome.top, width: width, height: safeHeight)
        guard let prevContent = previousImg.cropping(to: contentRect),
              let currContent = currentImg.cropping(to: contentRect) else { return nil }

        let scaleFactor: CGFloat
        let prevForVision: CGImage
        let currForVision: CGImage
        if let pv = prevContent.downscaled(maxDimension: 1024),
           let cv = currContent.downscaled(maxDimension: 1024) {
            scaleFactor = CGFloat(prevContent.width) / CGFloat(max(pv.width, 1))
            prevForVision = pv
            currForVision = cv
        } else {
            scaleFactor = 1
            prevForVision = prevContent
            currForVision = currContent
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currForVision)
        try? sequenceHandler.perform([request], on: prevForVision)

        var signedEstimate = safeHeight / 2
        var horizontalEstimate = 0
        if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
            let rawX = observation.alignmentTransform.tx * scaleFactor
            let rawY = observation.alignmentTransform.ty * scaleFactor
            // Vision occasionally reports non-finite/absurd transforms on a
            // malformed frame. Never convert those directly to Int.
            if rawX.isFinite, rawY.isFinite,
               abs(rawX) <= CGFloat(width) * 1.5,
               abs(rawY) <= CGFloat(height) * 1.5 {
                signedEstimate = -Int(rawY.rounded())
                horizontalEstimate = Int(rawX.rounded())
            } else if let estimate = pixelTranslation(previous: prevContent, current: currContent) {
                signedEstimate = estimate.y
                horizontalEstimate = estimate.x
            }
        } else if let estimate = pixelTranslation(previous: prevContent, current: currContent) {
            signedEstimate = estimate.y
            horizontalEstimate = estimate.x
        }

        if abs(horizontalEstimate) > max(5, abs(signedEstimate) * 2),
           let previous = transposed(prevContent),
           let current = transposed(currContent) {
            let right = horizontalEstimate >= 0
            let match = refineAlignmentWithvDSP(
                previous: right ? previous : current,
                current: right ? current : previous,
                estimatedShift: min(abs(horizontalEstimate), max(0, width - 1))
            )
            if match.shift > 5 && match.shift < width && match.quality <= 14 {
                return .horizontalScroll(shift: match.shift, right: right)
            }
        }

        let scrolledDown = signedEstimate >= 0
        let estimatedMagnitude = min(abs(signedEstimate), max(0, safeHeight - 1))
        let (magnitude, quality) = refineAlignmentWithvDSP(
            previous: scrolledDown ? prevContent : currContent,
            current: scrolledDown ? currContent : prevContent,
            estimatedShift: estimatedMagnitude
        )
        guard magnitude < safeHeight else { return .mismatch }

        let (staticTop, staticBottom) = compareFrameChrome(frameA: previousImg, frameB: currentImg)
        return classifyTransition(
            magnitude: magnitude,
            quality: quality,
            scrolledDown: scrolledDown,
            staticTop: staticTop,
            staticBottom: staticBottom,
            height: height
        )
    }

    /// Classifies a frame transition in the order the person asked for:
    /// is it a continued vertical scroll, then is it a horizontal carousel
    /// swipe, and only if neither fits, a mismatch that starts a new shot.
    ///
    /// `staticTop`/`staticBottom` come from a zero-shift, row-tolerant
    /// comparison of the two RAW frames (see `compareFrameChrome`): how many
    /// rows agree outright from the top, and from the bottom, with no
    /// translation applied at all. A real vertical scroll leaves almost
    /// nothing static that way (everything moved). A same-position content
    /// change (`.replace`, e.g. a "See more" expansion) typically leaves
    /// one side — usually the top — static all the way down to wherever the
    /// change starts, with little or nothing static on the OTHER side. A
    /// carousel swipe is the one case where a substantial run is static on
    /// BOTH sides at once, sandwiching a changed band in the interior —
    /// which is why this uses `min`, not `max`, of the two runs: it's the
    /// smaller of the two that proves the band is actually bounded rather
    /// than open-ended toward an edge. (Thresholds below were calibrated
    /// against this project's own carousel/replace/scroll sample pairs.)
    private func classifyTransition(
        magnitude: Int,
        quality: Float,
        scrolledDown: Bool,
        staticTop: Int,
        staticBottom: Int,
        height: Int
    ) -> SpanDirection {
        let bandTop = staticTop
        let bandBottomExclusive = height - staticBottom
        let bandHeight = bandBottomExclusive - bandTop
        let boundedFraction = Double(min(staticTop, staticBottom)) / Double(max(height, 1))

        let carouselLikely = bandHeight >= 40
            && bandHeight <= Int(Double(height) * 0.85)
            && boundedFraction >= 0.18

        // A strongly bounded-on-both-sides band is a signature real
        // scrolling essentially never produces (scrolling changes nearly
        // the whole frame), so it's checked before trusting a vertical
        // match — a coincidentally-plausible shift/quality score on two
        // unrelated carousel cards shouldn't be able to hide the swipe.
        if !carouselLikely {
            // Both Vision and the signed CPU search provide a measured translation.
            // Allow moderate overlay/codec noise across the three validation bands.
            let verticalQualityCeiling: Float = 40
            if magnitude > 5 && quality <= verticalQualityCeiling {
                return .verticalScroll(shift: magnitude, scrolledDown: scrolledDown)
            }
        }

        if carouselLikely {
            return .horizontalCarousel(top: bandTop, bottom: bandBottomExclusive)
        }

        if magnitude <= 5 && quality <= 40 {
            return .replace
        }

        return .mismatch
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
            if top == height { continue } // identical frames do not establish chrome
            // A mostly unchanged page or a carousel is not evidence of fixed headers.
            // Only viewport-wide movement can establish screen-locked chrome.
            if top + bottom > height / 2 || top > height / 4 || bottom > height / 4 { continue }
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
        let widthToCompare = min(firstFrame.width, referenceFrame.width)
        let rowTolerance: Int = 6 // same tolerance as compareFrameChrome, for consistency
        let rowCount = min(candidateTop, min(firstFrame.height, referenceFrame.height))
        let pixelStep = max(1, widthToCompare / 512)

        func rowIsStatic(_ y: Int) -> Bool {
            let offsetA = y * bytesPerRowA
            let offsetB = y * bytesPerRowB
            var total = 0
            var samples = 0
            for x in stride(from: 0, to: widthToCompare, by: pixelStep) {
                let a = offsetA + x * 4
                let b = offsetB + x * 4
                total += abs(Int(ptrA[a]) - Int(ptrB[b]))
                total += abs(Int(ptrA[a + 1]) - Int(ptrB[b + 1]))
                total += abs(Int(ptrA[a + 2]) - Int(ptrB[b + 2]))
                samples += 3
            }
            return samples > 0 && Double(total) / Double(samples) <= Double(rowTolerance)
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
              let dataB = frameB.dataProvider?.data,
              let ptrA = CFDataGetBytePtr(dataA),
              let ptrB = CFDataGetBytePtr(dataB) else { return (0, 0) }

        let height = min(frameA.height, frameB.height)
        let width = min(frameA.width, frameB.width)
        let bytesPerRowA = frameA.bytesPerRow
        let bytesPerRowB = frameB.bytesPerRow
        let rowTolerance: Int = 6 // mean RGB |diff|; small enough to reject real content changes
        let pixelStep = max(1, width / 512)

        func rowIsStatic(_ y: Int) -> Bool {
            let offsetA = y * bytesPerRowA
            let offsetB = y * bytesPerRowB
            var total = 0
            var samples = 0
            for x in stride(from: 0, to: width, by: pixelStep) {
                let a = offsetA + x * 4
                let b = offsetB + x * 4
                total += abs(Int(ptrA[a]) - Int(ptrB[b]))
                total += abs(Int(ptrA[a + 1]) - Int(ptrB[b + 1]))
                total += abs(Int(ptrA[a + 2]) - Int(ptrB[b + 2]))
                samples += 3
            }
            return samples > 0 && Double(total) / Double(samples) <= Double(rowTolerance)
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

    // MARK: - Low-allocation SAD Micro-Refinement

    /// Refines a coarse shift *magnitude* using sampled sum-of-absolute-
    /// differences across three overlap bands. This intentionally avoids the
    /// old per-shift Float-array allocations, which made long recordings hitch
    /// and spike memory while producing the same 0...255 quality scale.
    private func refineAlignmentWithvDSP(previous: CGImage, current: CGImage, estimatedShift: Int) -> (shift: Int, quality: Float) {
        guard let prevData = previous.dataProvider?.data,
              let currData = current.dataProvider?.data,
              let prevPtr = CFDataGetBytePtr(prevData),
              let currPtr = CFDataGetBytePtr(currData) else { return (estimatedShift, .greatestFiniteMagnitude) }

        let width = min(previous.width, current.width)
        let height = min(previous.height, current.height)
        let previousRowBytes = previous.bytesPerRow
        let currentRowBytes = current.bytesPerRow
        let bytesPerPixel = min(previous.bitsPerPixel, current.bitsPerPixel) / 8
        guard width > 0, height > 1, bytesPerPixel >= 3 else {
            return (estimatedShift, .greatestFiniteMagnitude)
        }

        let radius = 15
        let clampedEstimate = min(max(0, estimatedShift), height - 1)
        let start = max(0, clampedEstimate - radius)
        let end = min(height - 1, clampedEstimate + radius)
        guard start <= end else { return (clampedEstimate, .greatestFiniteMagnitude) }

        // Bound work on Retina frames while sampling the full width evenly.
        let pixelStep = max(1, width / 512)
        var bestShift = clampedEstimate
        var bestQuality = Float.greatestFiniteMagnitude

        for shift in start...end {
            let overlap = height - shift
            guard overlap > 0 else { continue }
            let bandRows = min(12, overlap)
            let bandStarts = [0, max(0, (overlap - bandRows) / 2), max(0, overlap - bandRows)]
            var total: UInt64 = 0
            var sampleCount: UInt64 = 0

            for bandStart in bandStarts {
                for row in bandStart..<(bandStart + bandRows) {
                    let previousOffset = (row + shift) * previousRowBytes
                    let currentOffset = row * currentRowBytes
                    for x in stride(from: 0, to: width, by: pixelStep) {
                        let a = previousOffset + x * bytesPerPixel
                        let b = currentOffset + x * bytesPerPixel
                        // Include alpha when present so the quality scale stays
                        // compatible with the previous packed-RGBA vDSP path.
                        for channel in 0..<min(4, bytesPerPixel) {
                            total += UInt64(abs(Int(prevPtr[a + channel]) - Int(currPtr[b + channel])))
                            sampleCount += 1
                        }
                    }
                }
            }

            guard sampleCount > 0 else { continue }
            let quality = Float(Double(total) / Double(sampleCount))
            if quality < bestQuality {
                bestQuality = quality
                bestShift = shift
            }
        }
        return (bestShift, bestQuality)
    }

    /// CPU fallback searches both signs and axes when Vision cannot register the frames.
    private func pixelTranslation(previous: CGImage, current: CGImage) -> (x: Int, y: Int)? {
        guard let a = previous.downscaled(maxDimension: 240).flatMap({ normalized($0) }),
              let b = current.downscaled(maxDimension: 240).flatMap({ normalized($0) }),
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return nil }
        let w = a.width, h = a.height
        var best = (x: 0, y: 0)
        var bestError = Double.greatestFiniteMagnitude
        for horizontal in [false, true] {
            let extent = horizontal ? w : h
            let limit = Int(Double(extent) * 0.85)
            for shift in -limit...limit {
                let dx = horizontal ? shift : 0, dy = horizontal ? 0 : shift
                let x0 = max(0, -dx), x1 = min(w, w - dx)
                let y0 = max(0, -dy), y1 = min(h, h - dy)
                var total: Double = 0
                var count = 0
                for y in stride(from: y0, to: y1, by: 4) {
                    for x in stride(from: x0, to: x1, by: 4) {
                        let ia = (y + dy) * a.bytesPerRow + (x + dx) * 4
                        let ib = y * b.bytesPerRow + x * 4
                        for c in 0..<3 { total += Double(abs(Int(pa[ia + c]) - Int(pb[ib + c]))) }
                        count += 3
                    }
                }
                let error = total / Double(max(1, count))
                if error < bestError { bestError = error; best = (dx, dy) }
            }
        }
        return (Int((CGFloat(best.x) * CGFloat(previous.width) / CGFloat(w)).rounded()),
                Int((CGFloat(best.y) * CGFloat(previous.height) / CGFloat(h)).rounded()))
    }

    /// Canonical packed RGBA makes pixel comparisons independent of decoder stride and color layout.
    private func normalized(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Turn columns into rows to use the same overlap measurement on both axes.
    private func transposed(_ image: CGImage) -> CGImage? {
        guard let source = normalized(image), let data = source.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let src = y * source.bytesPerRow + x * 4
                let dst = (x * source.height + y) * 4
                for channel in 0..<4 { pixels[dst + channel] = bytes[src + channel] }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: source.height, height: source.width, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: source.height * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Single-Pass Rendering Engine

    private func render(segments: [StitchSegment], canvasWidth: Int, canvasHeight: Int) -> CGImage? {
        guard canvasWidth > 0, canvasHeight > 0,
              Int64(canvasWidth) * Int64(canvasHeight) <= 100_000_000,
              let colorSpace = segments.first?.image.colorSpace else { return nil }

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
