import SwiftUI
#if canImport(UIKit)
import PhotosUI
import UIKit
#endif
import SwiftData
import os
import UniformTypeIdentifiers

/// A date-grouped photo library with batch actions and automatic Control Center imports.
struct StitchListView: View {
    @Query(sort: \Stitch.creationDate, order: .reverse) private var stitches: [Stitch]
    @Environment(\.modelContext) private var modelContext

    @State private var isPickingVideo = false
    @State private var path: [Stitch] = []
    @State private var createdStitch: Stitch?
    @State private var showRecordingHelp = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var handledRecordings: Set<URL> = []
    @State private var pendingImport: VideoImportSource?
    #if canImport(UIKit)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    @AppStorage("galleryCompact") private var compactGrid = false
    @AppStorage("galleryOldestFirst") private var oldestFirst = false
    @State private var filter: GalleryFilter = .all

    private enum GalleryFilter: String, CaseIterable, Identifiable {
        case all = "All", vertical = "Vertical", horizontal = "Horizontal"
        var id: String { rawValue }
    }

    private var visibleStitches: [Stitch] {
        let filtered = stitches.filter { stitch in
            guard filter != .all else { return true }
            guard let image = GalleryImage(data: stitch.imageData) else { return false }
            return filter == .horizontal ? image.isHorizontal : !image.isHorizontal
        }
        return oldestFirst ? Array(filtered.reversed()) : filtered
    }

    private var groupedStitches: [(date: Date, items: [Stitch])] {
        let groups = Dictionary(grouping: visibleStitches) { Calendar.current.startOfDay(for: $0.creationDate) }
        return groups.keys.sorted(by: oldestFirst ? (<) : (>)).map { ($0, groups[$0] ?? []) }
    }

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
        NavigationStack(path: $path) {
            ZStack {
                Group {
                    if stitches.isEmpty {
                        EmptyStitchListState(
                            onSelectVideo: { beginPicking() },
                            onRecord: { beginRecording() }
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
            .navigationTitle(isSelecting ? "\(selectedIDs.count) Selected" : "Captures")
            .toolbar {
                ToolbarItem(placement: leadingPlacement) {
                    if isSelecting {
                        Button(Set(visibleStitches.map(\.id)).isSubset(of: selectedIDs) ? "Deselect All" : "Select All") {
                            toggleSelectAll()
                        }
                        .disabled(visibleStitches.isEmpty)
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
                        Menu {
                            Picker("Thumbnail size", selection: $compactGrid) {
                                Text("Large thumbnails").tag(false)
                                Text("Small thumbnails").tag(true)
                            }
                            Picker("Sort", selection: $oldestFirst) {
                                Text("Newest first").tag(false)
                                Text("Oldest first").tag(true)
                            }
                            Divider()
                            Button("Record Screen", systemImage: "record.circle", action: beginRecording)
                        } label: { Label("Gallery Options", systemImage: "slider.horizontal.3") }
                        Button(action: { beginPicking() }) {
                            Label("Import Video", systemImage: "plus")
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
            .navigationDestination(for: Stitch.self) { stitch in
                StitchBrowserView(initialStitch: stitch, oldestFirst: oldestFirst, horizontalOnly: browsingFilter(for: stitch))
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                handledRecordings.removeAll()
                while !Task.isCancelled {
                    checkForRecordings()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .sheet(isPresented: $showRecordingHelp) {
                #if os(iOS)
                ReplayKitRecordingView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                #else
                NavigationStack {
                    ContentUnavailableView(
                        "Record on iPhone or iPad",
                        systemImage: "iphone",
                        description: Text("Screen Nibbles uses ReplayKit for direct screen capture on iOS. You can still import a compatible movie on this platform.")
                    )
                    .navigationTitle("Record Screen")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showRecordingHelp = false }
                        }
                    }
                }
                #endif
            }
            .sheet(item: $pendingImport, onDismiss: {
                if let createdStitch {
                    path.append(createdStitch)
                    self.createdStitch = nil
                }
            }) { source in
                NavigationStack {
                    VideoImportProcessingView(source: source) { stitch in
                        if createdStitch == nil { createdStitch = stitch }
                    }
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

    private var stitchFeedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your captures").font(.largeTitle.bold())
                        Text("\(stitches.count) image\(stitches.count == 1 ? "" : "s") · Pages, swipes, and everything in between")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Picker("Capture type", selection: $filter) {
                    ForEach(GalleryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if visibleStitches.isEmpty {
                    ContentUnavailableView("No \(filter.rawValue.lowercased()) images", systemImage: "photo.on.rectangle",
                        description: Text("Choose All to see the rest of your library."))
                        .frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(groupedStitches, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text(dayTitle(group.date)).font(.title3.bold())
                                    Spacer()
                                    Text("\(group.items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: compactGrid ? 100 : 150), spacing: 14)], spacing: 20) {
                                    ForEach(group.items) { stitch in
                                        StitchGridItem(stitch: stitch, isSelectionMode: isSelecting,
                                            isSelected: selectedIDs.contains(stitch.id),
                                            onToggleSelection: { toggleSelection(for: stitch) },
                                            onOpen: { path.append(stitch) },
                                            onSelect: { isSelecting = true; toggleSelection(for: stitch) })
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: compactGrid)
    }

    private func browsingFilter(for stitch: Stitch) -> Bool? {
        guard filter != .all else { return nil }
        let horizontal = filter == .horizontal
        // A newly imported capture should open even if it is outside the current filter.
        return GalleryImage(data: stitch.imageData)?.isHorizontal == horizontal ? horizontal : nil
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
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
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
        let visibleIDs = Set(visibleStitches.map(\.id))
        if visibleIDs.isSubset(of: selectedIDs) { selectedIDs.subtract(visibleIDs) }
        else { selectedIDs.formUnion(visibleIDs) }
        prepareBatchShareURLs()
    }

    private func prepareBatchShareURLs() {
        var urls: [URL] = []
        for stitch in selectedStitches {
            guard let data = stitch.imageData else { continue }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("stitch-\(stitch.id.uuidString).jpg")
            do { try data.write(to: tempURL, options: .atomic); urls.append(tempURL) }
            catch { triggerToast("Could not prepare one of the selected images") }
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
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if toastMessage == message {
                    showToast = false
                }
            }
        }
    }

    private func beginRecording() {
        showRecordingHelp = true
    }

    private func checkForRecordings() {
        #if os(iOS)
        guard pendingImport == nil, !isPickingVideo,
              let directory = BroadcastRecordingInbox.sharedRecordingsDirectory() else { return }
        BroadcastRecordingInbox.removeStalePartialSessions(
            in: directory,
            olderThan: Date().addingTimeInterval(-24 * 60 * 60)
        )
        guard let url = BroadcastRecordingInbox.readyRecordings(
            in: directory,
            excluding: handledRecordings
        ).first else { return }

        handledRecordings.insert(url)

        // A person normally opens this guide immediately before leaving the app
        // to record. When they come back, dismiss it before presenting the
        // processing sheet so SwiftUI never has to transition between two
        // competing sheet presentations in the same update cycle.
        if showRecordingHelp {
            showRecordingHelp = false
            Task { @MainActor in
                await Task.yield()
                pendingImport = .broadcastURL(url)
            }
        } else {
            pendingImport = .broadcastURL(url)
        }
        #endif
    }

    private func beginPicking() {
        Log.capture.info("Add tapped — opening video picker")
        isPickingVideo = true
    }
}

private struct EmptyStitchListState: View {
    var onSelectVideo: () -> Void
    var onRecord: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 8)

            Text("Welcome to Screen Nibbles")
                .font(.title2.bold())

            Text("Capture a scrolling screen and turn it into a continuous image. Vertical pages and horizontal swipes are stitched automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onRecord) {
                    Label("Record Screen", systemImage: "record.circle")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                }
                .buttonStyle(.borderedProminent)
                Button(action: onSelectVideo) {
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
