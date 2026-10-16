import AVFoundation
import DashCamKit
import Foundation
import SwiftUI

/// Shared state for the studio: the receiver, the clip inbox, the class
/// list, and the labels for whichever clip is open.
@MainActor
final class AppModel: ObservableObject {
    let workspace = Workspace()
    lazy var store = LabelStore(workspace: workspace)
    private lazy var receiver = OffloadReceiver(workspace: workspace)

    @Published var clips: [Clip] = []
    @Published var classes: [LabelClass] = []
    @Published var selectedClip: Clip?
    @Published var labels: ClipLabels = ClipLabels(clipFileName: "")
    @Published var log: [OffloadReceiver.Event] = []
    /// Files arriving right now, with byte progress.
    @Published var incoming: [OffloadReceiver.Progress] = []
    @Published var receiving = false
    @Published var statusMessage: String?
    @Published var busy = false

    /// Label counts per clip, for the sidebar badges.
    @Published var labelCounts: [String: Int] = [:]
    /// True when edits exist that haven't been written to the labels file.
    /// (Every edit is journalled immediately, so this is about the tidy
    /// saved file, never about losing work.)
    @Published var hasUnsavedChanges = false
    @Published var lastSavedAt: Date?
    @Published var offerCleanup = false
    @Published var lastExportFeatureCount = 0
    /// What the phone showed on screen during this clip's drive.
    @Published var detections: [PhoneDetection] = []
    @Published var review = ClipReview(clipFileName: "")

    // MARK: - Training console state
    /// Every exchange with the phone, oldest first.
    @Published var syncEvents: [SyncEvent] = []
    /// The phone's own account of the last import.
    @Published var phoneReport: PhoneReport?
    /// Tally of corrections across every clip.
    @Published var training = TrainingSummary(
        byClass: [], clipsReviewed: 0, boxesDrawn: 0, featuresReadyToSend: 0
    )
    /// Detections on the open clip that still need a verdict.
    var unreviewedCount: Int { max(0, detections.count - review.reviews.count) }

    init() {
        classes = store.loadClasses()
        refreshClips()
        refreshTraining()

        receiver.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.log.insert(event, at: 0)
                if self.log.count > 200 { self.log.removeLast(self.log.count - 200) }
                if event.kind == .received { self.refreshClips() }
            }
        }

        receiver.onSync = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.syncEvents.append(event)
                if self.syncEvents.count > 500 {
                    self.syncEvents.removeFirst(self.syncEvents.count - 500)
                }
                // A report from the phone changes the headline numbers.
                self.phoneReport = self.receiver.syncLog.latestReport()
            }
        }

        receiver.onProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                if progress.finished {
                    self.incoming.removeAll { $0.fileName == progress.fileName }
                } else if let index = self.incoming.firstIndex(where: { $0.fileName == progress.fileName }) {
                    self.incoming[index] = progress
                } else {
                    self.incoming.append(progress)
                }
            }
        }
    }

    /// Reloads everything the training console shows, from disk.
    func refreshTraining() {
        syncEvents = receiver.syncLog.events()
        phoneReport = receiver.syncLog.latestReport()
        training = TrainingSummary.build(store: store)
    }

    /// Records an exchange that happened on this side of the link.
    private func recordLocal(_ action: String, _ summary: String, _ outcome: SyncEvent.Outcome,
                             _ detail: [String: String] = [:]) {
        let event = SyncEvent(
            at: Date(), direction: .local, action: action,
            summary: summary, outcome: outcome, detail: detail
        )
        receiver.syncLog.append(event)
        syncEvents.append(event)
    }

    // MARK: - Receiver

    func startReceiver() {
        do {
            try receiver.start()
            receiving = true
        } catch {
            statusMessage = "Could not start receiver: \(error.localizedDescription)"
        }
    }

    func stopReceiver() {
        receiver.stop()
        receiving = false
    }

    // MARK: - Clips & labels

    func refreshClips() {
        clips = workspace.clips()
        var counts: [String: Int] = [:]
        for clip in clips {
            counts[clip.id] = store.labelCount(for: clip)
        }
        labelCounts = counts
    }

    func select(_ clip: Clip?) {
        if selectedClip != nil {
            saveLabels()
        }
        selectedClip = clip
        labels = clip.map { store.load(for: $0) } ?? ClipLabels(clipFileName: "")
        if let clip {
            labelCounts[clip.id] = labels.labels.count
            review = store.loadReview(for: clip)
            detections = clip.loadSidecar().map(DetectionExtractor.detections) ?? []
        } else {
            review = ClipReview(clipFileName: "")
            detections = []
        }
        hasUnsavedChanges = false
    }

    // MARK: - Reviewing phone detections

    func verdict(for detection: PhoneDetection) -> DetectionVerdict? {
        review.reviews.first { $0.detectionID == detection.id }?.verdict
    }

    /// Records a judgement on one of the phone's detections. Confirmed and
    /// corrected entries become road-memory features; rejected ones are kept
    /// as recorded false positives and never exported.
    func setVerdict(
        _ verdict: DetectionVerdict,
        for detection: PhoneDetection,
        className: String? = nil,
        value: String? = nil
    ) {
        guard let clip = selectedClip else { return }
        let entry = DetectionReview(
            detectionID: detection.id,
            verdict: verdict,
            className: className ?? detection.className,
            value: value ?? detection.value,
            time: detection.time
        )
        if let index = review.reviews.firstIndex(where: { $0.detectionID == detection.id }) {
            review.reviews[index] = entry
        } else {
            review.reviews.append(entry)
        }
        store.saveReview(review, for: clip)
        refreshTraining()

        // A boxed detection that's confirmed is training data as-is.
        if verdict != .rejected, let box = detection.box, box.count == 4 {
            let alreadyLabelled = labels.labels.contains {
                abs($0.time - detection.time) < 0.2 && $0.className == entry.className
            }
            if !alreadyLabelled {
                addLabel(FrameLabel(
                    time: detection.time, className: entry.className,
                    x: box[0], y: box[1], width: box[2], height: box[3],
                    value: entry.value
                ))
            }
        }
    }

    var reviewedCount: Int { review.reviews.count }
    var confirmedCount: Int { review.reviews.filter { $0.verdict != .rejected }.count }
    var rejectedCount: Int { review.reviews.filter { $0.verdict == .rejected }.count }

    /// Writes the tidy labels file and clears the journal.
    func saveLabels() {
        guard let clip = selectedClip else { return }
        store.save(labels, for: clip)
        labelCounts[clip.id] = labels.labels.count
        hasUnsavedChanges = false
        lastSavedAt = Date()
    }

    func addLabel(_ label: FrameLabel) {
        labels.labels.append(label)
        journal(.upsert, label)
    }

    func updateLabel(_ label: FrameLabel) {
        guard let index = labels.labels.firstIndex(where: { $0.id == label.id }) else { return }
        labels.labels[index] = label
        journal(.upsert, label)
    }

    func deleteLabel(id: UUID) {
        guard let label = labels.labels.first(where: { $0.id == id }) else { return }
        labels.labels.removeAll { $0.id == id }
        journal(.delete, label)
    }

    /// Every edit hits the append-only journal immediately — a crash or a
    /// force-quit can never lose labelling work.
    private func journal(_ change: LabelStore.Change, _ label: FrameLabel) {
        guard let clip = selectedClip else { return }
        store.appendJournal(change, label: label, for: clip)
        labelCounts[clip.id] = labels.labels.count
        hasUnsavedChanges = true
    }

    func labels(near time: Double, tolerance: Double = 0.05) -> [FrameLabel] {
        labels.labels.filter { abs($0.time - time) <= tolerance }
    }

    func labelClass(named name: String) -> LabelClass? {
        classes.first { $0.name == name }
    }

    // MARK: - Classes

    func saveClasses() {
        store.saveClasses(classes)
    }

    func addClass(_ labelClass: LabelClass) {
        guard !classes.contains(where: { $0.name == labelClass.name }) else { return }
        classes.append(labelClass)
        saveClasses()
    }

    func deleteClasses(at offsets: IndexSet) {
        classes.remove(atOffsets: offsets)
        saveClasses()
    }

    // MARK: - Export

    func exportRoadMemory() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try Exporters.exportRoadMemory(store: store, classes: classes)
                lastExportFeatureCount = result.featureCount
                recordLocal(
                    "Export corrections",
                    "Queued \(result.featureCount) corrected place(s) for the phone",
                    result.featureCount > 0 ? .ok : .info,
                    [
                        "features": "\(result.featureCount)",
                        "skipped (no GPS)": "\(result.skippedNoGPS)",
                        "file": result.url.lastPathComponent,
                    ]
                )
                refreshTraining()
                statusMessage = """
                Exported \(result.featureCount) road features. \
                \(result.skippedNoGPS > 0 ? "\(result.skippedNoGPS) label(s) had no GPS and were skipped. " : "")
                The phone picks this up automatically the next time it connects.
                """
                // Offer to reclaim disk now that the labels are exported.
                if !labelledClipsSafeToDelete.isEmpty {
                    offerCleanup = true
                }
            } catch {
                statusMessage = "Road memory export failed: \(error.localizedDescription)"
                recordLocal("Export corrections", error.localizedDescription, .failed)
            }
        }
    }

    /// Clips whose labelling work is already captured in the exported files —
    /// the videos themselves are no longer needed to keep that knowledge.
    var labelledClipsSafeToDelete: [Clip] {
        clips.filter { (labelCounts[$0.id] ?? 0) > 0 }
    }

    // MARK: - Deleting a single clip

    /// Removes one clip entirely — video, telemetry sidecar, labels, journal
    /// and detection review. Nothing about this clip survives.
    func deleteClipCompletely(_ clip: Clip) {
        let bytes = clip.byteSize
        try? FileManager.default.removeItem(at: clip.url)
        if let sidecar = clip.sidecarURL {
            try? FileManager.default.removeItem(at: sidecar)
        }
        store.deleteWork(for: clip)
        if selectedClip?.id == clip.id { select(nil) }
        refreshClips()
        statusMessage = "Deleted \(clip.fileName) and everything with it, freeing "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "."
    }

    /// Removes only the video file. Telemetry, labels and reviews stay, so
    /// the knowledge you extracted survives while the disk space comes back.
    func deleteVideoOnly(_ clip: Clip) {
        let bytes = clip.byteSize
        try? FileManager.default.removeItem(at: clip.url)
        if selectedClip?.id == clip.id { select(nil) }
        refreshClips()
        statusMessage = "Deleted the video for \(clip.fileName), freeing "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + ". Telemetry and labels were kept."
    }

    func revealInFinder(_ clip: Clip) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    /// Frees disk by deleting clip videos. Labels, telemetry sidecars and
    /// exports are kept, so nothing you tagged is lost.
    func deleteClipVideos(_ targets: [Clip], keepSidecars: Bool = true) {
        var removed = 0
        var bytes: Int64 = 0
        for clip in targets {
            bytes += clip.byteSize
            try? FileManager.default.removeItem(at: clip.url)
            if !keepSidecars, let sidecar = clip.sidecarURL {
                try? FileManager.default.removeItem(at: sidecar)
            }
            if selectedClip?.id == clip.id { select(nil) }
            removed += 1
        }
        refreshClips()
        statusMessage = "Deleted \(removed) video file(s), freeing \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
            + (keepSidecars ? " Labels and telemetry were kept." : "")
    }

    func exportTrainingDataset() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await Exporters.exportTrainingDataset(store: store)
                statusMessage = "Exported \(result.imageCount) frames / \(result.annotationCount) boxes to \(result.url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            } catch {
                statusMessage = "Dataset export failed: \(error.localizedDescription)"
            }
        }
    }

    func revealWorkspace() {
        NSWorkspace.shared.activateFileViewerSelecting([workspace.root])
    }
}
