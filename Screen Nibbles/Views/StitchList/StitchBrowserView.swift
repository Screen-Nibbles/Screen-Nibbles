import SwiftUI
import SwiftData

struct StitchBrowserView: View {
    @Query(sort: \Stitch.creationDate, order: .reverse) private var stitches: [Stitch]
    @State private var currentID: UUID
    var oldestFirst: Bool
    var horizontalOnly: Bool?

    init(initialStitch: Stitch, oldestFirst: Bool, horizontalOnly: Bool? = nil) {
        _currentID = State(initialValue: initialStitch.id)
        self.oldestFirst = oldestFirst
        self.horizontalOnly = horizontalOnly
    }

    private var ordered: [Stitch] {
        let images = stitches.filter { stitch in
            guard let horizontalOnly else { return true }
            return GalleryImage(data: stitch.imageData)?.isHorizontal == horizontalOnly
        }
        return oldestFirst ? Array(images.reversed()) : images
    }

    var body: some View {
        if let index = ordered.firstIndex(where: { $0.id == currentID }) {
            StitchDetailView(stitch: ordered[index], position: "\(index + 1) of \(ordered.count)",
                onPrevious: index > 0 ? { currentID = ordered[index - 1].id } : nil,
                onNext: index + 1 < ordered.count ? { currentID = ordered[index + 1].id } : nil)
                .id(currentID)
        } else {
            ContentUnavailableView("Image no longer available", systemImage: "photo")
        }
    }
}
