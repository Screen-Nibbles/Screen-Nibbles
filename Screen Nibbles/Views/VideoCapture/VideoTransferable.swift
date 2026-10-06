import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// A transferable representation for importing videos from the Photos framework.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = try VideoStorage.copyToLibrary(from: received.file)
            return VideoTransferable(url: copy)
        }
    }
}
