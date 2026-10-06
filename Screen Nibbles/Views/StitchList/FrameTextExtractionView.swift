import SwiftUI
import SwiftData
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Frame-first OCR workspace. The original recording is preferred because it
/// preserves sharp text, but every workflow can fall back to the stitched image.
struct FrameTextExtractionView: View {
    let stitch: Stitch

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var videoFrames: [TextFrame] = []
    @State private var stitchedFrame: TextFrame?
    @State private var crops: [String: NormalizedCrop] = [:]
    @State private var frameIndex = 0
    @State private var useStitchedImage = false
    @State private var cropMode: CropSelectionMode = .area
    @State private var isLoading = true
    @State private var isExtracting = false
    @State private var status = "Loading video frames…"
    @State private var notice: String?
    @State private var resultText = ""
    @State private var showResult = false
    @State private var copied = false
    @State private var extractionTask: Task<Void, Never>?

    private struct TextFrame: Identifiable {
        let id: String
        let image: CGImage
        let video: Video?
        let timestamp: Double
        let recording: Int
    }

    private var activeFrames: [TextFrame] {
        useStitchedImage ? stitchedFrame.map { [$0] } ?? [] : videoFrames
    }

    private var currentFrame: TextFrame? {
        activeFrames.indices.contains(frameIndex) ? activeFrames[frameIndex] : nil
    }

    private var selectedFrames: [TextFrame] {
        activeFrames.filter { hasUsableCrop(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView(status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let frame = currentFrame {
                sourceControls
                    .disabled(isExtracting)

                FrameCropCanvas(
                    image: frame.image,
                    selection: Binding(
                        get: { crops[frame.id] },
                        set: { crops[frame.id] = $0; resultText = "" }
                    ),
                    mode: cropMode
                )
                .disabled(isExtracting)

                if activeFrames.count > 1 {
                    frameStrip
                }

                frameControls
            } else {
                ContentUnavailableView(
                    "Frames unavailable",
                    systemImage: "text.viewfinder",
                    description: Text(notice ?? "Could not load this capture.")
                )
            }
        }
        .background(AppTheme.background)
        .navigationTitle("Select Text")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    persistCrops()
                    dismiss()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isLoading, currentFrame != nil { extractionControls }
        }
        .sheet(isPresented: $showResult) { textResult }
        .task { await loadFrames() }
        .onDisappear {
            extractionTask?.cancel()
            persistCrops()
        }
        .onChange(of: useStitchedImage) { _, _ in
            persistCrops()
            frameIndex = 0
            ensureTrimCropIfNeeded()
        }
        .onChange(of: cropMode) { _, mode in
            if mode == .trimEdges { ensureTrimCropIfNeeded() }
        }
        .onChange(of: frameIndex) { _, _ in
            ensureTrimCropIfNeeded()
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !videoFrames.isEmpty, stitchedFrame != nil {
                Picker("Text source", selection: $useStitchedImage) {
                    Text("Frames").tag(false)
                    Text("Stitched Image").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Text source")
            }

            Picker("Selection style", selection: $cropMode) {
                ForEach(CropSelectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Selection style")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: cropMode == .trimEdges ? "crop" : "selection.pin.in.out")
                    .foregroundStyle(.secondary)
                Text(cropMode == .trimEdges
                     ? "Drag any edge inward to ignore browser chrome, margins, or incomplete frame edges."
                     : "Drag around the text you want. Move the selection or resize it from a corner.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(activeFrames.indices, id: \.self) { index in
                        let frame = activeFrames[index]
                        Button {
                            persistCrops()
                            frameIndex = index
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(platformImage: .from(cgImage: frame.image))
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 74)
                                    .clipped()

                                if hasUsableCrop(for: frame) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .padding(4)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(index == frameIndex ? Color.accentColor : Color.primary.opacity(0.10),
                                            lineWidth: index == frameIndex ? 3 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Frame \(index + 1)")
                        .accessibilityValue(index == frameIndex ? "Current" : "")
                        .id(index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(AppTheme.card)
            .onChange(of: frameIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var frameControls: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    persistCrops()
                    frameIndex -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .disabled(frameIndex == 0)
                .accessibilityLabel("Previous frame")

                Spacer()

                VStack(spacing: 2) {
                    Text(useStitchedImage ? "Stitched image" : "Frame \(frameIndex + 1) of \(activeFrames.count)")
                        .font(.subheadline.weight(.semibold))
                    if let frame = currentFrame, !useStitchedImage {
                        Text("Recording \(frame.recording) · \(frame.timestamp.formatted(.number.precision(.fractionLength(1))))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    persistCrops()
                    frameIndex += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .disabled(frameIndex + 1 >= activeFrames.count)
                .accessibilityLabel("Next frame")
            }
            .buttonStyle(.plain)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    selectionUtilityButtons
                    Spacer(minLength: 8)
                    selectionCount
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { selectionUtilityButtons }
                    selectionCount
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .disabled(isExtracting)
    }

    @ViewBuilder
    private var selectionUtilityButtons: some View {
        Button(cropMode == .trimEdges ? "Reset Edges" : "Whole Frame") {
            setWholeFrameCrop()
        }
        .frame(minHeight: 44)

        Button("Clear") {
            guard let frame = currentFrame else { return }
            crops[frame.id] = nil
            resultText = ""
        }
        .frame(minHeight: 44)
        .disabled(currentFrame.map { crops[$0.id] == nil } ?? true)

        if activeFrames.count > 1, currentFrame.map({ hasUsableCrop(for: $0) }) == true {
            Button("Apply to All") { applyCurrentCropToAllFrames() }
                .frame(minHeight: 44)
        }
    }

    private var selectionCount: some View {
        Text("\(selectedFrames.count) selected")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var extractionButtons: some View {
        Button {
            if let frame = currentFrame { extract([frame]) }
        } label: {
            Label("Read Frame", systemImage: "text.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .disabled(isExtracting || currentFrame.map({ !hasUsableCrop(for: $0) }) ?? true)

        Button {
            extract(selectedFrames)
        } label: {
            Label("Read Selected (\(selectedFrames.count))", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .disabled(isExtracting || selectedFrames.isEmpty)
    }

    private var extractionControls: some View {
        VStack(spacing: 8) {
            if isExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { extractionButtons }
                VStack(spacing: 10) { extractionButtons }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var textResult: some View {
        NavigationStack {
            TextEditor(text: $resultText)
                .font(.body)
                .padding()
                .navigationTitle("Selected Text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showResult = false }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied ? "Copied" : "Copy") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = resultText
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(resultText, forType: .string)
                            #endif
                            copied = true
                        }
                        .disabled(resultText.isEmpty)
                    }
                }
                .onChange(of: resultText) { _, _ in copied = false }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
    }

    private func loadFrames() async {
        if let data = stitch.imageData {
            let decoded = await Task.detached(priority: .userInitiated) {
                // Keep the stitched fallback useful for edge selection without
                // retaining an unbounded full-resolution panorama in memory.
                GalleryImage.thumbnail(data: data, maxPixelSize: 8_000)
            }.value
            if let decoded {
                stitchedFrame = TextFrame(id: "stitched", image: decoded, video: nil, timestamp: 0, recording: 0)
            }
        }

        let videos = stitch.videos ?? []
        var failedRecordings = 0
        var missingRecordings = 0

        for (index, video) in videos.enumerated() {
            if let data = video.textCropData,
               let saved = try? JSONDecoder().decode([String: NormalizedCrop].self, from: data) {
                for (key, crop) in saved { crops["\(video.id):\(key)"] = crop }
            }

            guard let sourceURL = video.existingURL else {
                missingRecordings += 1
                continue
            }

            do {
                try Task.checkCancellation()
                status = "Loading recording \(index + 1) of \(videos.count)…"
                let frames = try await VideoToShotsConverter.extractFrames(from: sourceURL, maxFrameDimension: 1000)
                for frame in frames {
                    guard let image = frame.image.cgImage else { continue }
                    videoFrames.append(TextFrame(
                        id: "\(video.id):\(key(for: frame.timestamp))",
                        image: image,
                        video: video,
                        timestamp: frame.timestamp,
                        recording: index + 1
                    ))
                }
                if frames.isEmpty { failedRecordings += 1 }
            } catch is CancellationError {
                return
            } catch {
                failedRecordings += 1
            }
        }

        useStitchedImage = videoFrames.isEmpty
        if missingRecordings > 0 {
            notice = missingRecordings == videos.count
                ? "The original recording is no longer available. Text can still be selected from the stitched image."
                : "One original recording is missing. Available frames and the stitched image can still be used."
        } else if failedRecordings > 0 {
            notice = "Some source frames could not be decoded. Available frames and the stitched image can still be used."
        }

        isLoading = false
        ensureTrimCropIfNeeded()
    }

    private func key(for timestamp: Double) -> String {
        String(Int64((timestamp * 1000).rounded()))
    }

    private func hasUsableCrop(for frame: TextFrame) -> Bool {
        crops[frame.id]?.pixelRect(width: frame.image.width, height: frame.image.height) != nil
    }

    private func setWholeFrameCrop() {
        guard let frame = currentFrame else { return }
        crops[frame.id] = NormalizedCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        resultText = ""
    }

    private func ensureTrimCropIfNeeded() {
        guard cropMode == .trimEdges, let frame = currentFrame, crops[frame.id] == nil else { return }
        crops[frame.id] = NormalizedCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func applyCurrentCropToAllFrames() {
        guard let frame = currentFrame, let crop = crops[frame.id] else { return }
        for target in activeFrames { crops[target.id] = crop }
        resultText = ""
    }

    private func persistCrops() {
        guard !isLoading else { return }
        var changed = false
        for video in stitch.videos ?? [] {
            let prefix = "\(video.id):"
            let saved = crops.reduce(into: [String: NormalizedCrop]()) { result, entry in
                if entry.key.hasPrefix(prefix) {
                    result[String(entry.key.dropFirst(prefix.count))] = entry.value
                }
            }
            do {
                video.textCropData = try JSONEncoder().encode(saved)
                changed = true
            } catch {
                notice = "Could not save text selections."
                return
            }
        }
        guard changed else { return }
        do { try modelContext.save() }
        catch { notice = "Could not save text selections." }
    }

    /// Source-frame previews stay modest in memory. OCR re-decodes just the
    /// frame being read at near-native iPhone resolution, so a long capture
    /// doesn't keep dozens of full-resolution screen images resident at once.
    private func recognitionImage(for frame: TextFrame) async throws -> CGImage {
        guard let video = frame.video, let sourceURL = video.existingURL else {
            if frame.id == "stitched", let data = stitch.imageData {
                return await Task.detached(priority: .userInitiated) {
                    GalleryImage.thumbnail(data: data, maxPixelSize: 12_000)
                }.value ?? frame.image
            }
            return frame.image
        }

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2600, height: 2600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        do {
            let result = try await generator.image(
                at: CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            )
            return result.image
        } catch {
            // The preview still represents the same normalized crop and is a
            // useful fallback if an exact high-resolution decode fails.
            return frame.image
        }
    }

    private func extract(_ frames: [TextFrame]) {
        persistCrops()
        isExtracting = true
        notice = nil
        let selections = crops
        extractionTask?.cancel()
        extractionTask = Task {
            defer { isExtracting = false }
            do {
                var texts: [String] = []
                for (index, frame) in frames.enumerated() {
                    try Task.checkCancellation()
                    status = "Reading \(index + 1) of \(frames.count)…"
                    let recognitionImage = try await recognitionImage(for: frame)
                    guard let rect = selections[frame.id]?.pixelRect(
                        width: recognitionImage.width,
                        height: recognitionImage.height
                    ), let cropped = recognitionImage.cropping(to: rect) else { continue }

                    let options = OCRFilterOptions(
                        filterMenusAndButtons: false,
                        filterDatesAndTimes: false,
                        deduplicateRepeatedLines: false,
                        autoRotate: false
                    )
                    let result = try await OCRUtils.extractText(from: cropped, options: options)
                    if !result.fullText.isEmpty { texts.append(result.fullText) }
                }
                try Task.checkCancellation()
                resultText = texts.joined(separator: "\n\n")
                if resultText.isEmpty {
                    notice = "No text found in the selected areas. Try a larger selection or reset the trim edges."
                } else {
                    copied = false
                    showResult = true
                }
            } catch is CancellationError {
                return
            } catch {
                notice = "Text extraction failed: \(error.localizedDescription)"
            }
        }
    }
}
