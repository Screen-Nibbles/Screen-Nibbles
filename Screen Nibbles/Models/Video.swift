import Foundation
import SwiftData

/// Represents a source video used to generate stitched panoramas.
@Model
final class Video {
    var id: UUID
    /// The filename of the video, resolved against the app's documents directory.
    var filename: String
    var duration: TimeInterval
    var creationDate: Date
    /// Normalized text-selection rectangles keyed by extracted-frame timestamp.
    @Attribute(.externalStorage) var textCropData: Data?

    @Relationship(inverse: \Stitch.videos)
    var stitches: [Stitch]?

    init(
        filename: String,
        duration: TimeInterval = 0,
        creationDate: Date = Date()
    ) {
        self.id = UUID()
        self.filename = filename
        self.duration = duration
        self.creationDate = creationDate
        self.textCropData = nil
    }

    /// The preferred file URL for newly imported videos.
    var url: URL {
        VideoStorage.directory.appendingPathComponent(filename)
    }

    /// A readable source URL, including the legacy Documents location used by
    /// older builds. Missing originals are expected after restores/cleanup and
    /// should be handled as a recoverable state rather than a file-system error.
    var existingURL: URL? { VideoStorage.existingURL(for: filename) }
}
