import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An expressive image viewer card for a single stitch with
/// metadata tags (dimensions, aspect ratio, source), multi-selection support, split action, and quick actions.
struct StitchGridItem: View {
    var stitch: Stitch
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext

    @State private var fullImage: PlatformImage?
    @State private var imageDimensions: CGSize = .zero
    @State private var tempShareURL: URL?
    @State private var showCopiedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Top Header
            HStack(alignment: .center, spacing: 8) {
                if isSelectionMode {
                    Button {
                        onToggleSelection?()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(stitch.creationDate, style: .date)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let video = stitch.videos?.first {
                        Text(video.filename)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if imageDimensions != .zero {
                    Text("\(Int(imageDimensions.width)) × \(Int(imageDimensions.height))")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }

                if !isSelectionMode {
                    Menu {
                        Button(action: copyImage) {
                            Label("Copy Image", systemImage: "doc.on.doc")
                        }

                        if let tempShareURL {
                            ShareLink(item: tempShareURL) {
                                Label("Share Image", systemImage: "square.and.arrow.up")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: deleteStitch) {
                            Label("Delete Stitch", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.card)

            Divider()

            // Main Image Viewer Canvas
            ZStack {
                Color.black.opacity(0.04)

                if let image = fullImage {
                    if imageDimensions.width > imageDimensions.height && imageDimensions.width > 0 {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 240)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .frame(height: 256)
                    } else {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 380)
                            .padding(8)
                    }
                } else {
                    Rectangle()
                        .fill(AppTheme.surface)
                        .frame(height: 240)
                        .overlay(ProgressView())
                        .task { await loadImageData() }
                }

                if isSelectionMode && isSelected {
                    Color.accentColor.opacity(0.12)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Rectangle())
            .onTapGesture {
                if isSelectionMode {
                    onToggleSelection?()
                }
            }

            Divider()

            // Bottom Quick-Action Bar
            if !isSelectionMode {
                HStack(spacing: 0) {
                    Button(action: copyImage) {
                        HStack(spacing: 4) {
                            Image(systemName: showCopiedAlert ? "checkmark" : "doc.on.doc")
                            Text(showCopiedAlert ? "Copied" : "Copy")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(showCopiedAlert ? .green : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if let tempShareURL {
                        ShareLink(item: tempShareURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(AppTheme.card)
            }
        }
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isSelected && isSelectionMode ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected && isSelectionMode ? 2 : 1
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
        .task {
            prepareShareURL()
        }
    }

    private func copyImage() {
        guard let data = stitch.imageData else { return }
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            triggerCopiedFeedback()
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            triggerCopiedFeedback()
        }
        #endif
    }

    private func triggerCopiedFeedback() {
        showCopiedAlert = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                showCopiedAlert = false
            }
        }
    }

    private func prepareShareURL() {
        guard let data = stitch.imageData else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stitch-\(stitch.id.uuidString).jpg")
        try? data.write(to: url)
        tempShareURL = url
    }

    private func deleteStitch() {
        modelContext.delete(stitch)
    }

    private func loadImageData() async {
        guard let data = stitch.imageData else { return }
        let image = PlatformImage(data: data)
        if let cg = image?.cgImage {
            imageDimensions = CGSize(width: cg.width, height: cg.height)
        }
        fullImage = image
    }
}
