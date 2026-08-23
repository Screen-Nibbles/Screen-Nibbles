import SwiftUI
#if canImport(UIKit)
import PhotosUI
#endif
import SwiftData
import os
import UniformTypeIdentifiers

/// The primary stitch gallery screen: on iOS, renders a clean single-column image viewer stream
/// with distinct visual cards, multi-selection for batch sharing/exporting, and ReplayKit screen recording.
struct StitchListView: View {
    @Query(sort: \Stitch.creationDate, order: .reverse) private var stitches: [Stitch]
    @Environment(\.modelContext) private var modelContext

    @State private var isPickingVideo = false
    @State private var pendingImport: VideoImportSource?
    #if canImport(UIKit)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    // Multi-selection state
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var batchShareURLs: [URL] = []
    @State private var showDeleteConfirmation = false
    @State private var toastMessage: String?
    @State private var showToast = false



    private var selectedStitches: [Stitch] {
        stitches.filter { selectedIDs.contains($0.id) }
    }

    private var leadingPlacement: ToolbarItemPlacement {
        #if os(macOS)
        return .navigation
        #else
        return .topBarLeading
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if stitches.isEmpty {
                        EmptyStitchListState(
                            onSelectVideo: { beginPicking() }
                        )
                    } else {
                        stitchFeedView
                    }
                }
                .background(AppTheme.background)



                // Toast overlay
                if showToast, let toastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(toastMessage)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85))
                        .clipShape(Capsule())
                        .shadow(radius: 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, isSelecting ? 80 : 24)
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
                }
            }
            .navigationTitle(isSelecting ? "\(selectedIDs.count) Selected" : "Screen Nibbles")
            .toolbar {
                ToolbarItem(placement: leadingPlacement) {
                    if isSelecting {
                        Button(selectedIDs.count == stitches.count ? "Deselect All" : "Select All") {
                            toggleSelectAll()
                        }
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if !stitches.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIDs.removeAll()
                                    batchShareURLs.removeAll()
                                }
                            }
                        }
                    }

                    if !isSelecting {
                        Button(action: { beginPicking() }) {
                            Label("Select Video", systemImage: "plus")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedIDs.isEmpty {
                    selectionActionBar
                }
            }
            #if canImport(UIKit)
            .photosPicker(isPresented: $isPickingVideo, selection: $selectedPhotoItem, matching: .videos)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else {
                    Log.capture.notice("Photo picker dismissed without a selection")
                    return
                }
                Log.capture.info("Photo picker returned an item")
                pendingImport = .photoItem(newItem)
                selectedPhotoItem = nil
            }
            #else
            .fileImporter(isPresented: $isPickingVideo, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url):
                    Log.capture.info("File picker returned \(url.lastPathComponent, privacy: .public)")
                    pendingImport = .fileURL(url)
                case .failure(let error):
                    Log.capture.notice("File picker cancelled or failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            #endif
            .sheet(item: $pendingImport) { source in
                NavigationStack {
                    VideoImportProcessingView(source: source) { _ in }
                }
                #if canImport(AppKit)
                .frame(width: 700, height: 560)
                #endif
            }
            .confirmationDialog(
                "Delete \(selectedIDs.count) Stitch\(selectedIDs.count == 1 ? "" : "es")?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteSelectedStitches()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Single-column feed view ensuring clear visual distinction, rich card viewer framing, and high visibility.
    private var stitchFeedView: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(stitches) { stitch in
                    let isSelected = selectedIDs.contains(stitch.id)

                    Group {
                        if isSelecting {
                            StitchGridItem(
                                stitch: stitch,
                                isSelectionMode: true,
                                isSelected: isSelected,
                                onToggleSelection: {
                                    toggleSelection(for: stitch)
                                }
                            )
                        } else {
                            NavigationLink(value: stitch) {
                                StitchGridItem(
                                    stitch: stitch,
                                    isSelectionMode: false,
                                    isSelected: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationDestination(for: Stitch.self) { stitch in
            StitchDetailView(stitch: stitch)
        }
    }

    /// Floating bottom action bar during multi-selection mode.
    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            if !batchShareURLs.isEmpty {
                ShareLink(items: batchShareURLs) {
                    Label("Share (\(selectedIDs.count))", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    prepareBatchShareURLs()
                } label: {
                    Label("Share (\(selectedIDs.count))", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: selectedIDs) { _, _ in
            prepareBatchShareURLs()
        }
    }



    private func toggleSelection(for stitch: Stitch) {
        if selectedIDs.contains(stitch.id) {
            selectedIDs.remove(stitch.id)
        } else {
            selectedIDs.insert(stitch.id)
        }
        prepareBatchShareURLs()
    }

    private func toggleSelectAll() {
        if selectedIDs.count == stitches.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(stitches.map { $0.id })
        }
        prepareBatchShareURLs()
    }

    private func prepareBatchShareURLs() {
        var urls: [URL] = []
        for stitch in selectedStitches {
            guard let data = stitch.imageData else { continue }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("stitch-\(stitch.id.uuidString).jpg")
            try? data.write(to: tempURL)
            urls.append(tempURL)
        }
        batchShareURLs = urls
    }



    private func deleteSelectedStitches() {
        let count = selectedIDs.count
        for stitch in selectedStitches {
            modelContext.delete(stitch)
        }
        selectedIDs.removeAll()
        batchShareURLs.removeAll()
        isSelecting = false
        triggerToast("Deleted \(count) stitch\(count == 1 ? "" : "es")")
    }

    private func triggerToast(_ message: String) {
        toastMessage = message
        showToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if toastMessage == message {
                    showToast = false
                }
            }
        }
    }

    private func beginPicking() {
        Log.capture.info("Add tapped — opening video picker")
        isPickingVideo = true
    }
}

private struct EmptyStitchListState: View {
    var onSelectVideo: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 8)

            Text("Welcome to Screen Nibbles")
                .font(.title2.bold())

            Text("Select a video to automatically stitch your moments into a continuous panorama.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {                Button(action: onSelectVideo) {
                    Label("Select Video from Library", systemImage: "film.stack")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 32))
        .padding()
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
