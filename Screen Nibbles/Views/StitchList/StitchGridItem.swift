import SwiftUI
import SwiftData

/// An image-first tile; actions live in its context menu instead of crowding the grid.
struct StitchGridItem: View {
    var stitch: Stitch
    var isSelectionMode = false
    var isSelected = false
    var onToggleSelection: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSelect: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var thumbnail: PlatformImage?
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    private var metadata: GalleryImage? { GalleryImage(data: stitch.imageData) }

    var body: some View {
        Button {
            if isSelectionMode { onToggleSelection?() }
            else { onOpen?() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        AppTheme.surface
                        if let thumbnail {
                            Image(platformImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                                .clipped()
                        } else {
                            Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if isSelectionMode {
                            Color.black.opacity(isSelected ? 0.15 : 0.04)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(isSelected ? Color.accentColor : .white)
                                .background(.white.opacity(isSelected ? 1 : 0.15), in: Circle())
                                .padding(10)
                        }
                        VStack {
                            Spacer()
                            HStack {
                                Label(metadata?.isHorizontal == true ? "Horizontal" : "Vertical",
                                      systemImage: metadata?.isHorizontal == true ? "arrow.left.and.right" : "arrow.up.and.down")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.regularMaterial, in: Capsule())
                                Spacer()
                            }
                            .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isSelected ? 3 : 1))
                }
                .aspectRatio(1, contentMode: .fit)
                HStack {
                    Text(stitch.creationDate, format: .dateTime.hour().minute())
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 2)
                    if let metadata {
                        Text(metadata.dimensions).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metadata?.isHorizontal == true ? "Horizontal" : "Vertical") capture, \(stitch.creationDate.formatted())")
        .accessibilityValue(isSelectionMode ? (isSelected ? "Selected" : "Not selected") : "")
        .contextMenu {
            if !isSelectionMode {
                Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { onOpen?() }
                Button("Select", systemImage: "checkmark.circle") { onSelect?() }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share Image", systemImage: "square.and.arrow.up") }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete this image?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { modelContext.delete(stitch) }
        }
        .task(id: stitch.id) {
            guard let data = stitch.imageData else { return }
            let cgImage = await Task.detached(priority: .utility) { GalleryImage.thumbnail(data: data) }.value
            guard !Task.isCancelled else { return }
            if let cgImage { thumbnail = .from(cgImage: cgImage) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stitch-\(stitch.id).jpg")
            do { try data.write(to: url, options: .atomic); shareURL = url }
            catch { shareURL = nil }
        }
    }
}
