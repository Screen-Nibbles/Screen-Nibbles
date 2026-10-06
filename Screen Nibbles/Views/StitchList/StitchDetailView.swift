import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Clean, high-performance image viewer for a stitched screenshot with double-tap zoom,
/// scrollable zoom, Copy, text extraction, and Share.
struct StitchDetailView: View {
    @Bindable var stitch: Stitch
    var position: String? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var showTextSelection = false
    @State private var confirmDelete = false
    @State private var toastMessage: String?
    @State private var isShowingToast = false
    @State private var displayImage: CGImage?
    @State private var imageLoadFailed = false

    // Zoom state
    @State private var currentZoomScale: CGFloat = 1.0
    @State private var zoomAtGestureStart: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let image = displayImage {
                    let width = CGFloat(image.width)
                    let height = CGFloat(image.height)
                    let fit = min(1, width > height ? geometry.size.height / height : geometry.size.width / width)
                    Image(platformImage: .from(cgImage: image))
                        .resizable()
                        .frame(width: max(1, width * fit * currentZoomScale), height: max(1, height * fit * currentZoomScale))
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentZoomScale = currentZoomScale > 1 ? 1 : 2.5
                                zoomAtGestureStart = currentZoomScale
                            }
                        }
                        .simultaneousGesture(MagnifyGesture()
                            .onChanged { currentZoomScale = min(8, max(0.25, zoomAtGestureStart * $0.magnification)) }
                            .onEnded { _ in zoomAtGestureStart = currentZoomScale })
                } else if imageLoadFailed || stitch.imageData == nil {
                    ContentUnavailableView("Image Unavailable", systemImage: "photo", description: Text("Could not load this capture."))
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                } else {
                    ProgressView("Opening capture…")
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .scrollIndicators(.automatic)
        }
        .background(AppTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { browserControls }
        .overlay(alignment: .bottom) {
            if isShowingToast, let toastMessage {
                Text(toastMessage).font(.caption.weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 140).allowsHitTesting(false)
            }
        }
        .navigationTitle(stitch.creationDate.formatted(date: .abbreviated, time: .shortened))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Copy Image", systemImage: "doc.on.doc", action: copyImageToClipboard)
                    Button("Select Text", systemImage: "text.viewfinder") { showTextSelection = true }
                    if let exportURL { ShareLink(item: exportURL) { Label("Share Image", systemImage: "square.and.arrow.up") } }
                    Divider()
                    Button("Delete Image", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Label("Image Actions", systemImage: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Delete this image?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteStitch)
        }
        .sheet(isPresented: $showTextSelection) {
            NavigationStack { FrameTextExtractionView(stitch: stitch) }
            #if os(macOS)
            .frame(minWidth: 760, minHeight: 700)
            #endif
        }
        .task(id: stitch.id) {
            await loadDisplayImage()
            prepareExportURL()
        }
    }

    private var browserControls: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    imageNavigationControls
                    Spacer(minLength: 8)
                    zoomControls
                }
                VStack(spacing: 6) {
                    if position != nil {
                        HStack(spacing: 12) {
                            imageNavigationControls
                            Spacer()
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        zoomControls
                    }
                }
            }
            .buttonStyle(.plain)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    viewerActionButtons
                }
                VStack(spacing: 10) {
                    viewerActionButtons
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }


    @ViewBuilder
    private var imageNavigationControls: some View {
        if let position {
            Button { onPrevious?() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(onPrevious == nil)
            .accessibilityLabel("Previous image")

            Text(position)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Image \(position)")

            Button { onNext?() } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(onNext == nil)
            .accessibilityLabel("Next image")
        }
    }

    @ViewBuilder
    private var zoomControls: some View {
        Button {
            setZoom(currentZoomScale / 1.5)
        } label: {
            Image(systemName: "minus.magnifyingglass")
                .frame(width: 44, height: 44)
        }
        .disabled(currentZoomScale <= 0.25)
        .accessibilityLabel("Zoom out")

        Text("\(Int((currentZoomScale * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 42)
            .accessibilityLabel("Zoom \(Int((currentZoomScale * 100).rounded())) percent")

        Button {
            setZoom(currentZoomScale * 1.5)
        } label: {
            Image(systemName: "plus.magnifyingglass")
                .frame(width: 44, height: 44)
        }
        .disabled(currentZoomScale >= 8)
        .accessibilityLabel("Zoom in")

        Button {
            setZoom(1)
        } label: {
            Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                .frame(minHeight: 44)
        }
        .disabled(currentZoomScale == 1)
        .accessibilityHint("Fits the capture to the browsing direction")
    }

    private func setZoom(_ proposed: CGFloat) {
        currentZoomScale = min(8, max(0.25, proposed))
        zoomAtGestureStart = currentZoomScale
    }


    @ViewBuilder
    private var viewerActionButtons: some View {
        Button(action: copyImageToClipboard) {
            Label("Copy", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
        }

        Button { showTextSelection = true } label: {
            Label("Select Text", systemImage: "text.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        if let exportURL {
            ShareLink(item: exportURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func copyImageToClipboard() {
        #if canImport(UIKit)
        if let data = stitch.imageData {
            // Preserve the original JPEG without inflating a potentially huge
            // panorama into another full-resolution bitmap.
            UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
            triggerToast("Copied image to clipboard")
            return
        }
        guard let image = displayImage else {
            triggerToast("Image is still loading")
            return
        }
        UIPasteboard.general.image = UIImage(cgImage: image)
        triggerToast("Copied image to clipboard")
        #elseif canImport(AppKit)
        guard let image = displayImage else {
            triggerToast("Image is still loading")
            return
        }
        let platformImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([platformImage])
        triggerToast("Copied image to clipboard")
        #endif
    }

    private func deleteStitch() {
        modelContext.delete(stitch)
        dismiss()
    }

    private func prepareExportURL() {
        guard let data = stitch.imageData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stitch-\(stitch.id.uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { triggerToast("Could not prepare image for sharing") }
    }

    private func loadDisplayImage() async {
        guard let data = stitch.imageData else {
            imageLoadFailed = true
            return
        }
        imageLoadFailed = false
        let decoded = await Task.detached(priority: .userInitiated) {
            // A decoded 40k-pixel panorama can consume hundreds of MB on an
            // iPhone. Keep the interactive viewer bounded while retaining the
            // original JPEG for export/copy and the source video for OCR.
            GalleryImage.thumbnail(data: data, maxPixelSize: 12_000)
        }.value
        guard !Task.isCancelled else { return }
        displayImage = decoded
        imageLoadFailed = decoded == nil
    }

    private func triggerToast(_ message: String) {
        toastMessage = message
        isShowingToast = true
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
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
