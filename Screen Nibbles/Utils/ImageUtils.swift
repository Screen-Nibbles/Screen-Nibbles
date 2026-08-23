import SwiftUI
import CoreGraphics
import CoreVideo
import ImageIO
import AVFoundation
import CoreImage
import Foundation
import os

#if canImport(UIKit)
import UIKit
/// A platform-agnostic alias for images, resolving to `UIImage` on iOS/visionOS.
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
/// A platform-agnostic alias for images, resolving to `NSImage` on macOS.
public typealias PlatformImage = NSImage

extension NSImage {
    /// Retrieves the underlying `CGImage`, mirroring `UIImage`'s API.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Converts the image to JPEG data, mirroring `UIImage`'s API.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

// MARK: - Cross-Platform Image Extensions

extension PlatformImage {
    /// Creates a platform image from a `CGImage`.
    static func from(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

extension Image {
    /// Initializes a SwiftUI `Image` from a cross-platform image type.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Downscales the image so its longest edge is at most `maxDimension` pixels, preserving aspect ratio.
    ///
    /// - Parameter maxDimension: The maximum dimension in pixels.
    /// - Returns: A downscaled image, or the original if it is already smaller.
    func downsized(maxDimension: CGFloat) -> PlatformImage {
        guard let cgImage else { return self }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longestEdge = max(width, height)
        guard longestEdge > maxDimension, longestEdge > 0 else { return self }

        let scale = maxDimension / longestEdge
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Log.frames.notice("Couldn't create a downsize context for a \(Int(width), privacy: .public)x\(Int(height), privacy: .public) frame — keeping it full-size")
            return self
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = context.makeImage() else {
            Log.frames.notice("Downsize draw produced no image — keeping full-size frame")
            return self
        }
        Log.frames.debug("Downsized frame \(Int(width), privacy: .public)x\(Int(height), privacy: .public) → \(newWidth, privacy: .public)x\(newHeight, privacy: .public)")
        return PlatformImage.from(cgImage: resized)
    }
}

// MARK: - Centralized Logging Facilities

/// Centralized logging facilities for the application.
enum Log {
    private static let subsystem = "com.tomaslin.Screen-Nibbles"

    /// Logger for the application's video capture and import flow.
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Logger for frame extraction and analysis processes.
    static let frames = Logger(subsystem: subsystem, category: "frames")
    /// Logger for the image stitching pipeline.
    static let stitch = Logger(subsystem: subsystem, category: "stitch")
}
