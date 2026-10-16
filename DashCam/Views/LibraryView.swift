import SwiftData
import SwiftUI

/// Media viewer: Loop / Saved sections with an All / Tagged filter.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var offload: OffloadService
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ClipSegment.createdAt, order: .reverse)
    private var clips: [ClipSegment]

    @State private var taggedOnly = false
    @State private var clipPendingDelete: ClipSegment?
    @State private var isPreparingShare = false
    @State private var shareURL: URL?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmBulkDelete = false

    private var filteredClips: [ClipSegment] {
        clips.filter { clip in
            !taggedOnly || !clip.tags.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("Filter", selection: $taggedOnly) {
                    Text("All").tag(false)
                    Text("Tagged").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 80)

                if filteredClips.isEmpty {
                    ContentUnavailableView(
                        taggedOnly ? "No tagged clips" : "No clips yet",
                        systemImage: "film.stack",
                        description: Text(
                            taggedOnly
                                ? "Tag a moment while recording and it shows up here."
                                : "Recordings appear here. Tagged and saved clips (🔒) are protected; the rest are overwritten oldest-first when space runs low."
                        )
                    )
                    Spacer()
                } else {
                    List(selection: $selection) {
                        ForEach(filteredClips) { clip in
                            NavigationLink {
                                PlayerView(clip: clip)
                                    .id(clip.id)
                            } label: {
                                ClipRow(clip: clip)
                            }
                            .tag(clip.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    requestDelete(clip)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if clip.folder == .loop {
                                    Button {
                                        library.saveToProtected(clip)
                                    } label: {
                                        Label("Protect", systemImage: "lock.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .contextMenu {
                                clipActions(clip)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                // A real view, not a .bottomBar toolbar item: in a landscape
                // sheet iOS collapses bottom-bar buttons to zero width, which
                // made the delete button untappable.
                if editMode.isEditing {
                    selectionBar
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isPreparingShare {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Exporting with telemetry overlay…")
                            .font(.caption)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { shareURL != nil },
                    set: { if !$0 { shareURL = nil } }
                )
            ) {
                if let shareURL {
                    ActivityShareSheet(items: [shareURL])
                }
            }
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !filteredClips.isEmpty {
                        Button(editMode.isEditing ? "Cancel" : "Select") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                                selection.removeAll()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editMode.isEditing {
                        Button(selection.count == filteredClips.count ? "Deselect All" : "Select All") {
                            selection = selection.count == filteredClips.count
                                ? []
                                : Set(filteredClips.map(\.id))
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .alert("Delete \(selection.count) clip\(selection.count == 1 ? "" : "s")?",
                   isPresented: $confirmBulkDelete) {
                Button("Delete permanently", role: .destructive) {
                    deleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(bulkDeleteMessage)
            }
            .alert(
                "Delete this clip?",
                isPresented: Binding(
                    get: { clipPendingDelete != nil },
                    set: { if !$0 { clipPendingDelete = nil } }
                ),
                presenting: clipPendingDelete
            ) { clip in
                Button("Delete permanently", role: .destructive) {
                    library.delete(clip, context: context)
                    clipPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { clipPendingDelete = nil }
            } message: { clip in
                Text(deleteMessage(for: clip))
            }
        }
        // Attached outside the NavigationStack so it can never collide with
        // the delete confirmation above.
        .alert(
            "Library",
            isPresented: Binding(
                get: { library.exportMessage != nil || library.actionError != nil },
                set: { if !$0 { library.exportMessage = nil; library.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.exportMessage ?? library.actionError ?? "")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Text(selectionSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                offloadSelected()
            } label: {
                Label("Offload \(selection.count)", systemImage: "arrow.up.doc.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(canOffloadSelection ? Color.blue : Color.gray.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canOffloadSelection)
            .accessibilityIdentifier("bulkOffloadButton")

            Button {
                confirmBulkDelete = true
            } label: {
                Label("Delete \(selection.count)", systemImage: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        selection.isEmpty ? Color.gray.opacity(0.4) : Color.red,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("bulkDeleteButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Selected clips, with protected ones counted so the confirmation can
    /// call them out — those are never auto-deleted, so removing them is a
    /// deliberate act.
    private var selectedClips: [ClipSegment] {
        filteredClips.filter { selection.contains($0.id) }
    }

    private var selectionSummary: String {
        guard !selection.isEmpty else {
            return offload.helperFound
                ? "Select clips to offload or delete"
                : "Select clips to delete · Mac not found"
        }
        let bytes = selectedClips.reduce(Int64(0)) { $0 + $1.fileSize }
        // Offloading removes the phone's copy once the Mac verifies it, so
        // call out protected clips before they leave the device.
        let locked = selectedClips.filter { $0.folder == .saved }.count
        let lockedNote = locked > 0 ? " · \(locked) 🔒" : ""
        return "\(selection.count) selected · \(Format.fileSize(bytes))\(lockedNote)"
    }

    /// Offloading needs a Mac on the network and a stopped camera — the
    /// upload competes with the writer otherwise.
    private var canOffloadSelection: Bool {
        !selection.isEmpty && offload.helperFound && !offload.isBusy
    }

    /// Sends only the chosen clips, so the Mac's disk fills on your terms.
    private func offloadSelected() {
        let targets = selectedClips
        guard !targets.isEmpty else { return }
        offload.startOffload(clips: targets)
        DiagLog.shared.info("Library: offloading \(targets.count) selected clip(s)")
        selection.removeAll()
        withAnimation { editMode = .inactive }
        dismiss()
    }

    private var bulkDeleteMessage: String {
        let protectedCount = selectedClips.filter { $0.folder == .saved }.count
        let bytes = selectedClips.reduce(Int64(0)) { $0 + $1.fileSize }
        var message = "This frees \(Format.fileSize(bytes)) and removes the clips and their telemetry permanently."
        if protectedCount > 0 {
            message = "\(protectedCount) of these are protected (🔒) and would never be auto-deleted. " + message
        }
        return message
    }

    private func deleteSelected() {
        let targets = selectedClips
        for clip in targets {
            library.delete(clip, context: context)
        }
        DiagLog.shared.info("Library: bulk-deleted \(targets.count) clip(s)")
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    private func deleteMessage(for clip: ClipSegment) -> String {
        let detail = "\(Format.clipDate(clip.createdAt)) — \(Format.duration(clip.duration))."
        return clip.folder == .saved
            ? "\(detail) This clip is in the protected Saved folder. Deleting removes it and its telemetry permanently."
            : "\(detail) Deleting removes the clip and its telemetry permanently."
    }

    @ViewBuilder
    private func clipActions(_ clip: ClipSegment) -> some View {
        if clip.folder == .loop {
            Button {
                library.saveToProtected(clip)
            } label: {
                Label("Protect (never auto-delete)", systemImage: "lock.fill")
            }
        }
        Button {
            Task { await library.exportToPhotos(clip) }
        } label: {
            Label("Export to Photos", systemImage: "photo.badge.arrow.down")
        }
        Button {
            Task {
                isPreparingShare = true
                defer { isPreparingShare = false }
                do {
                    shareURL = try await library.burnedExportURL(for: clip)
                } catch {
                    library.actionError = error.localizedDescription
                }
            }
        } label: {
            Label("Share with overlay", systemImage: "square.and.arrow.up")
        }
        ShareLink(item: library.videoURL(for: clip)) {
            Label("Share original (no overlay)", systemImage: "square.and.arrow.up.circle")
        }
        Button(role: .destructive) {
            requestDelete(clip)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func requestDelete(_ clip: ClipSegment) {
        // Every deletion is confirmed — loop clips included.
        clipPendingDelete = clip
    }
}

/// One clip in the library list: thumbnail, date/time, duration, size,
/// resolution badge, tag-count badge.
struct ClipRow: View {
    @EnvironmentObject private var library: LibraryViewModel
    let clip: ClipSegment

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.25))
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(Format.clipDate(clip.createdAt))
                    .font(.subheadline.bold())
                Text("\(Format.duration(clip.duration)) • \(Format.fileSize(clip.fileSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    if clip.folder == .saved {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Protected")
                    }
                    Text(clip.resolution.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.25), in: Capsule())
                }
                if !clip.tags.isEmpty {
                    Label("\(clip.tags.count)", systemImage: "bookmark.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.yellow.opacity(0.2), in: Capsule())
                }
            }
        }
        .task(id: clip.fileName) {
            thumbnail = await library.thumbnails.thumbnail(for: library.videoURL(for: clip))
        }
    }
}
