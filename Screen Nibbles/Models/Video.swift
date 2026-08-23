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
    }

    /// The resolved file URL of the video in the documents directory.
    var url: URL {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return urls[0].appendingPathComponent(filename)
    }
}
