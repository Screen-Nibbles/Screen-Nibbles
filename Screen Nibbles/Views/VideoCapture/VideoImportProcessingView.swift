import SwiftUI
#if canImport(UIKit)
import PhotosUI
#endif
import SwiftData
import AVFoundation
import os

/// Where an in-progress video import came from — either a picked file, photo item, or live recording URL.
enum VideoImportSource: Identifiable {
    case fileURL(URL)
    #if canImport(UIKit)
    case photoItem(PhotosPickerItem)
    #endif

    var id: String {
        switch self {
        case .fileURL(let url):
            return url.absoluteString
        #if canImport(UIKit)
        case .photoItem(let item):
            return item.itemIdentifier ?? UUID().uuidString
        #endif
        }
    }
}

/// A view that orchestrates the video import pipeline, extracting and stitching frames into a seamless panorama.
struct VideoImportProcessingView: View {
    var source: VideoImportSource
    var onStitchCreated: (Stitch) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0.0
    @State private var statusText = "Finding the best moments…"
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ImportErrorState(message: errorMessage) { dismiss() }
            } else {
                ProcessingIndicator(progress: progress, statusText: statusText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
        .navigationTitle("Processing Video")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task { await beginImport() }
    }

    /// Resolves the source video and begins processing.
    private func beginImport() async {
        Log.capture.info("Beginning import — source: \(String(describing: source), privacy: .public)")
        do {
            let url: URL
            switch source {
            case .fileURL(let sourceURL):
                url = try await localCopy(of: sourceURL)
            #if canImport(UIKit)
            case .photoItem(let item):
                statusText = "Loading video…"
                Log.capture.info("Loading video data from the selected photo library item")
                guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                    Log.capture.error("Photo library item produced no transferable video")
                    throw VideoImportError.couldNotLoadVideo
                }
                Log.capture.info("Loaded video from photo library into \(movie.url.lastPathComponent, privacy: .public)")
                url = movie.url
            #endif
            }
            await processVideoURL(url: url)
        } catch {
            Log.capture.error("Import failed before processing could start: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func localCopy(of sourceURL: URL) async throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let localURL = URL.documentsDirectory.appendingPathComponent("video_\(UUID().uuidString).\(ext)")
        Log.capture.info("Copying picked file \(sourceURL.lastPathComponent, privacy: .public) into app storage as \(localURL.lastPathComponent, privacy: .public)")
        try FileManager.default.copyItem(at: sourceURL, to: localURL)
        return localURL
    }

    private func processVideoURL(url: URL) async {
        statusText = "Finding the best moments…"
        progress = 0.0
        Log.capture.info("Extracting frames from \(url.lastPathComponent, privacy: .public)")

        do {
            let converter = VideoToShotsConverter()
            let frames = try await converter.convert(from: url) { p in
                Task { @MainActor in self.progress = p }
            }
            Log.capture.info("Extracted \(frames.count, privacy: .public) candidate frame(s) from \(url.lastPathComponent, privacy: .public)")

            guard !frames.isEmpty else {
                Log.capture.notice("No distinct paused moments found in \(url.lastPathComponent, privacy: .public) — nothing to stitch")
                errorMessage = "Could not find any distinct moments to stitch in this video."
                return
            }

            statusText = "Stitching frames together…"
            progress = 0.0
            Log.capture.info("Stitching \(frames.count, privacy: .public) frame(s) together")
            let stitcher = ShotsToStitchesConverter()
            let stitchedImages = try await stitcher.stitch(images: frames.map(\.image)) { p in
                Task { @MainActor in self.progress = p }
            }

            guard !stitchedImages.isEmpty else {
                Log.capture.error("Stitching produced no usable image for \(url.lastPathComponent, privacy: .public)")
                errorMessage = "Could not determine how these frames overlap."
                return
            }

            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            let video = Video(filename: url.lastPathComponent, duration: duration)
            modelContext.insert(video)

            for stitchedImage in stitchedImages {
                guard let imageData = stitchedImage.jpegData(compressionQuality: 0.9) else { continue }
                Log.capture.info("Stitch complete: \(imageData.count, privacy: .public) byte(s), source duration \(duration, format: .fixed(precision: 1), privacy: .public)s")

                let stitch = Stitch(
                    imageData: imageData,
                    videos: [video]
                )
                modelContext.insert(stitch)
                Log.capture.info("Saved new stitch \(stitch.id.uuidString, privacy: .public)")
                onStitchCreated(stitch)
            }

            dismiss()
        } catch {
            Log.capture.error("Processing failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}

/// A determinate progress indicator shown while frames are extracted and stitched.
struct ProcessingIndicator: View {
    var progress: Double
    var statusText: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .padding(.horizontal, 40)
            Text("\(statusText)\n\(Int(progress * 100))%")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

/// An inline error state, with a way to close out of the processing sheet.
struct ImportErrorState: View {
    var message: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

enum VideoImportError: LocalizedError {
    case couldNotLoadVideo

    var errorDescription: String? {
        switch self {
        case .couldNotLoadVideo:
            return "Could not load the selected video."
        }
    }
}
