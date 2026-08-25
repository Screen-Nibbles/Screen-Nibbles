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
        var lastVerticalFrame = allCGImages[0]
        let sequenceHandler = VNSequenceRequestHandler()

        // A capture can contain more than one distinct "shot": a vertical
        // scroll can be interrupted by a horizontal carousel swipe, or by a
        // jump too large/unrelated to explain as either. `finishedResults`
        // collects every fully-resolved group (carousel strips, and vertical
        // panoramas that got cut short by a mismatch) as the loop goes;
        // `segments`/`topCursor`/`bottomCursor` always describe the vertical
        // group that's still open.
        var finishedResults: [PlatformImage] = []

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
            }
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
            }
            guard !segments.isEmpty else { return }

            if segments.count == 1 && verticalSeedIsRedundant {
                // Nothing but the shared seed frame — already preserved as
                // the carousel's first card. Skip emitting a duplicate.
                return
            }

            if chrome.bottom > 0 {
                segments.append(
                    StitchSegment(
                        image: lastVerticalFrame,
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
                  let image = render(segments: segments, canvasWidth: width, canvasHeight: totalHeight) else { return }
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
            lastVerticalFrame = anchor
            verticalSeedIsRedundant = false
        }

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

                let (magnitude, quality) = refineAlignmentWithvDSP(
                    previous: prevContent,
                    current: currContent,
                    estimatedShift: estimatedMagnitude,
                    isFallback: isFallback
                )

                // A shift that pins against the safe-height ceiling couldn't
                // be meaningfully searched — it's the clamp talking, not a
                // real measurement. Rather than silently dropping the frame
                // (losing whatever it captured), treat it the same as any
                // other unexplainable jump: close out what's open and start
                // a fresh shot from here.
                guard magnitude < initialSafeHeight else {
                    flushCarousel()
                    flushVerticalGroup()
                    startNewVerticalGroup(anchor: currentImg)
                    return
                }

                // Row-tolerant, zero-shift comparison of the two RAW frames
                // (not just the chrome-cropped content band). This is the
                // same measurement `detectStaticChrome` uses per-pair, reused
                // here to find, for THIS pair, how much of the frame agrees
                // outright with no shift at all — the signature of a bounded
                // sub-region changing (a carousel swipe) rather than the
                // whole viewport moving (a scroll) or everything disagreeing
                // at once (a mismatch).
                let (staticTop, staticBottom) = compareFrameChrome(frameA: previousImg, frameB: currentImg)
                let direction = classifyTransition(
                    magnitude: magnitude,
                    quality: quality,
                    visionSucceeded: !isFallback,
                    staticTop: staticTop,
                    staticBottom: staticBottom,
                    height: height
                )

                switch direction {
                case .verticalScroll:
                    flushCarousel()
                    let drawHeight = CGFloat(magnitude)

                    // Redraw the CURRENT frame's *entire* visible content
                    // band — not just the sliver of new content the shift
                    // revealed — positioned so its already-seen portion
                    // lands exactly back on top of whatever the previous
                    // frame(s) already drew there. `render(segments:...)`
                    // draws segments in append order, so this later
                    // (lower-in-the-scroll) frame's pixels always win over
                    // the earlier frame's pixels in that shared band, the
                    // same "later capture wins" rule used for `.replace`
                    // below. Without this, only the brand-new sliver got the
                    // current frame's pixels and the overlap region kept
                    // whatever the older frame drew — so a floating/
                    // transient element (e.g. a nav pill) that happened to
                    // render into an earlier frame but not the current one
                    // would stick around, and vice versa.
                    if scrolledDown {
                        // Bottom edge of the full band already lines up with
                        // this frame's own bottom (minus chrome); its top
                        // now reaches up into the previously-drawn overlap.
                        // (`height - chrome.bottom - initialSafeHeight == chrome.top`.)
                        let drawTop = bottomCursor + drawHeight - CGFloat(initialSafeHeight)
                        segments.append(
                            StitchSegment(
                                image: currentImg,
                                cropRect: CGRect(x: 0, y: CGFloat(chrome.top), width: CGFloat(width), height: CGFloat(initialSafeHeight)),
                                drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: CGFloat(initialSafeHeight))
                            )
                        )
                        bottomCursor += drawHeight
                    } else {
                        // Top edge of the full band already lines up with
                        // this frame's own top (plus chrome); its bottom now
                        // reaches down into the previously-drawn overlap.
                        let cropY = chrome.top
                        let drawTop = topCursor - drawHeight
                        segments.append(
                            StitchSegment(
                                image: currentImg,
                                cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: CGFloat(initialSafeHeight)),
                                drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: CGFloat(initialSafeHeight))
                            )
                        )
                        topCursor -= drawHeight
                    }
                    lastVerticalFrame = currentImg

                case .horizontalCarousel(let bandTop, let bandBottomExclusive):
                    // Same viewport position, but a bounded band swapped
                    // horizontally (a carousel swipe) rather than the small,
                    // page-wide disagreement `.replace` handles. Keep it out
                    // of the vertical stitch entirely and build/extend a
                    // separate side-by-side strip instead. The vertical
                    // group's current segment (its most recent frame, i.e.
                    // `previousImg`) becomes the strip's first card, so that
                    // frame stays part of the vertical scroll too.
                    appendCarouselFrame(previous: previousImg, current: currentImg, bandTop: bandTop, bandBottomExclusive: bandBottomExclusive)

                case .replace:
                    flushCarousel()
                    // A near-zero magnitude doesn't necessarily mean
                    // "nothing changed" — it means Vision/vDSP couldn't find
                    // a confident *scroll* offset, which is exactly what
                    // happens when two frames show the same viewport
                    // position but disagree in a sub-region (a live element
                    // redrew, a modal appeared, etc). Treat it as a
                    // same-position "replace": overlay this frame's full
                    // content band on top of whatever's already drawn there
                    // so far, so the later capture wins wherever the two
                    // disagree, rather than being blended pixel-by-pixel or
                    // thrown away.
                    let overlapHeight = min(CGFloat(initialSafeHeight), bottomCursor - topCursor)
                    if overlapHeight > 0 {
                        let cropY = height - chrome.bottom - Int(overlapHeight)
                        let drawTop = bottomCursor - overlapHeight
                        segments.append(
                            StitchSegment(
                                image: currentImg,
                                cropRect: CGRect(x: 0, y: CGFloat(cropY), width: CGFloat(width), height: overlapHeight),
                                drawRect: CGRect(x: 0, y: drawTop, width: CGFloat(width), height: overlapHeight)
                            )
                        )
                        lastVerticalFrame = currentImg
                    }

                case .mismatch:
                    // Neither a vertical scroll nor a bounded carousel band
                    // explains this transition — too different to be the
                    // same shot. Close out whatever's open and start clean.
                    flushCarousel()
                    flushVerticalGroup()
                    startNewVerticalGroup(anchor: currentImg)
                }
            }
            progress(Double(i) / Double(allCGImages.count))
        }

        flushCarousel()
        flushVerticalGroup()

        guard !finishedResults.isEmpty else {
            throw ShotsToStitchesError.compositingFailed
        }

        progress(1.0)
        return finishedResults
    }

    // MARK: - Frame-Transition Classification

    /// What relationship, if any, connects two consecutive frames.
    private enum SpanDirection: Equatable {
        /// The page scrolled; `currentImg` extends the open vertical group.
        case verticalScroll
        /// Same scroll position, but a bounded row band swapped out (a
        /// carousel swipe). `top`/`bottom` are the rows (in the ORIGINAL,
        /// uncropped frame) that changed and should be split into their own
        /// side-by-side strip.
        case horizontalCarousel(top: Int, bottom: Int)
        /// Same scroll position, no bounded band — a small in-place content
        /// change (e.g. a live widget re-rendering). Overlaid onto the open
        /// vertical group.
        case replace
        /// Too different to explain as any of the above; starts a new shot.
        case mismatch
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
        visionSucceeded: Bool,
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
            // Vision reporting an explicit alignment is real evidence of a
            // translational relationship, so a moderate quality score is
            // still trusted. With no Vision result at all, the wide-radius
            // vDSP fallback search is blind and more prone to false
            // matches on unrelated content, so it's held to a tighter bar.
            let verticalQualityCeiling: Float = visionSucceeded ? 40 : 14
            if magnitude > 5 && quality <= verticalQualityCeiling {
                return .verticalScroll
            }
        }

        if carouselLikely {
            return .horizontalCarousel(top: bandTop, bottom: bandBottomExclusive)
        }

        if magnitude <= 5 {
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
    /// Also returns the match quality at that best shift — the mean
    /// per-byte absolute difference (0 = identical, 255 = maximally
    /// different) — so the caller can judge how much to trust it.
    private func refineAlignmentWithvDSP(previous: CGImage, current: CGImage, estimatedShift: Int, isFallback: Bool) -> (shift: Int, quality: Float) {
        guard let prevData = previous.dataProvider?.data,
              let currData = current.dataProvider?.data else { return (estimatedShift, .greatestFiniteMagnitude) }

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
        guard startY <= endY else { return (estimatedShift, .greatestFiniteMagnitude) }

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

        let quality = lowestDiff.isFinite ? lowestDiff / Float(totalFloats) : .greatestFiniteMagnitude
        return (bestShift, quality)
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
