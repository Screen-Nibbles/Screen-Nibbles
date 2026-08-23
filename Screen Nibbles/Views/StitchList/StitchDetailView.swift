import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Clean, high-performance image viewer for a stitched screenshot with double-tap zoom,
/// 1-click Split into pages/carousels, Copy, and Share.
struct StitchDetailView: View {
    @Bindable var stitch: Stitch
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var toastMessage: String?
    @State private var isShowingToast = false

    // Zoom state
    @State private var currentZoomScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            ScrollView([.horizontal, .vertical]) {
                if let data = stitch.imageData, let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(currentZoomScale)
                        .gesture(
                            TapGesture(count: 2).onEnded {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    currentZoomScale = currentZoomScale > 1.0 ? 1.0 : 2.5
                                }
                            }
                        )
                        .contextMenu {
                            Button(action: copyImageToClipboard) {
                                Label("Copy Image", systemImage: "doc.on.doc")
                            }

                            Button(action: extractTextAndCopy) {
                                Label("Extract Text", systemImage: "text.viewfinder")
                            }

                            if let exportURL {
                                ShareLink(item: exportURL) {
                                    Label("Share Image", systemImage: "square.and.arrow.up")
                                }
                            }

                            Divider()

                            Button(role: .destructive, action: deleteStitch) {
                                Label("Delete Stitch", systemImage: "trash")
                            }
                        }
                } else {
                    ContentUnavailableView(
                        "Image Unavailable",
                        systemImage: "photo",
                        description: Text("Could not load image data for this stitch.")
                    )
                }
            }
            .background(AppTheme.background)

            // Dynamic bottom floating pill for quick actions
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button(action: copyImageToClipboard) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)

                    Button(action: extractTextAndCopy) {
                        Label("Extract", systemImage: "text.viewfinder")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                .padding(.bottom, 16)
            }

            // Toast feedback
            if isShowingToast, let toastMessage {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isShowingToast)
            }
        }
        .navigationTitle(stitch.creationDate.formatted(date: .abbreviated, time: .shortened))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: copyImageToClipboard) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button(action: extractTextAndCopy) {
                        Label("Extract Text", systemImage: "text.viewfinder")
                    }

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Image", systemImage: "square.and.arrow.up")
                        }
                    }

                    Divider()

                    Button(role: .destructive, action: deleteStitch) {
                        Label("Delete Stitch", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            prepareExportURL()
        }
    }

    private func copyImageToClipboard() {
        guard let data = stitch.imageData else { return }
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            triggerToast("Copied image to clipboard")
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            triggerToast("Copied image to clipboard")
        }
        #endif
    }

    private func extractTextAndCopy() {
        guard let data = stitch.imageData else { return }
        Task {
            do {
                let result = try await OCRUtils.extractText(from: data, options: .standard)
                let text = result.fullText
                if text.isEmpty {
                    await MainActor.run { triggerToast("No text found") }
                    return
                }
                await MainActor.run {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = text
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                    triggerToast("Copied text to clipboard")
                }
            } catch {
                await MainActor.run { triggerToast("Extraction failed") }
            }
        }
    }

    private func deleteStitch() {
        modelContext.delete(stitch)
        dismiss()
    }

    private func prepareExportURL() {
        guard let data = stitch.imageData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitch-\(stitch.id.uuidString).jpg")
        try? data.write(to: url)
        exportURL = url
    }

    private func triggerToast(_ message: String) {
        toastMessage = message
        isShowingToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if toastMessage == message {
                    isShowingToast = false
                }
            }
        }
    }
}
