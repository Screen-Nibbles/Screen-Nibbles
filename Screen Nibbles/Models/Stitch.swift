import Foundation
import SwiftData

/// Represents a stitched panorama image generated from a video source.
@Model
final class Stitch {
    var id: UUID
    var creationDate: Date
    @Attribute(.externalStorage) var imageData: Data?

    /// The source videos from which this stitch was created.
    var videos: [Video]?

    init(
        creationDate: Date = Date(),
        imageData: Data? = nil,
        videos: [Video] = []
    ) {
        self.id = UUID()
        self.creationDate = creationDate
        self.imageData = imageData
        self.videos = videos
    }
}
