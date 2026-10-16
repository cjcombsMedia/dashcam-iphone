import Foundation
import Photos
import SwiftData

/// Per-clip actions for the media viewer: save-to-protected, export, delete.
@MainActor
final class LibraryViewModel: ObservableObject {
    let thumbnails = ThumbnailGenerator()
    private let tagStore: TagStore
    private let storage: StorageManager
    private let settings: AppSettings

    @Published var exportMessage: String?
    @Published var actionError: String?

    init(tagStore: TagStore, storage: StorageManager, settings: AppSettings) {
        self.tagStore = tagStore
        self.storage = storage
        self.settings = settings
    }

    func videoURL(for clip: ClipSegment) -> URL {
        tagStore.videoURL(for: clip)
    }

    func sidecar(for clip: ClipSegment) -> TelemetrySidecar? {
        // Even when the model lost track of the sidecar name, the file sits
        // next to its video with the same base name.
        let name = clip.sidecarFileName
            ?? (clip.fileName as NSString).deletingPathExtension + ".json"
        let url = storage.url(forFileName: name, in: clip.folder)
        guard let data = try? Data(contentsOf: url) else {
            DiagLog.shared.error("Telemetry sidecar missing for \(clip.fileName) (looked for \(name) in \(clip.folder.rawValue))")
            return nil
        }
        do {
            return try TelemetrySidecar.decoder().decode(TelemetrySidecar.self, from: data)
        } catch {
            DiagLog.shared.error("Telemetry sidecar unreadable for \(clip.fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Prepares a copy for sharing/exporting in the chosen mode.
    func burnedExportURL(for clip: ClipSegment, mode: ExportMode = .basicOverlay) async throws -> URL {
        try await TelemetryBurner.burn(
            videoURL: videoURL(for: clip),
            sidecar: sidecar(for: clip),
            fallbackDate: clip.createdAt,
            unit: settings.speedUnit,
            mode: mode
        )
    }

    func saveToProtected(_ clip: ClipSegment) {
        do {
            try tagStore.saveToProtected(clip)
        } catch {
            DiagLog.shared.error("Save-to-protected failed for \(clip.fileName): \(error.localizedDescription)")
            actionError = "Couldn't move the clip to Saved: \(error.localizedDescription)"
        }
    }

    func delete(_ clip: ClipSegment, context: ModelContext) {
        do {
            try tagStore.delete(clip, context: context)
        } catch {
            DiagLog.shared.error("Delete failed for \(clip.fileName): \(error.localizedDescription)")
            actionError = "Couldn't delete the clip: \(error.localizedDescription)"
        }
    }

    func exportToPhotos(_ clip: ClipSegment) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            actionError = "Photos access is required to export. Enable it in Settings."
            return
        }
        do {
            // Exports carry the telemetry overlay; fall back to the raw
            // file if the burn fails so an export always succeeds.
            let url: URL
            do {
                url = try await burnedExportURL(for: clip, mode: .basicOverlay)
            } catch {
                DiagLog.shared.error("Overlay burn failed for \(clip.fileName), exporting raw: \(error.localizedDescription)")
                url = videoURL(for: clip)
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            exportMessage = "Exported to Photos with telemetry overlay."
        } catch {
            DiagLog.shared.error("Photos export failed for \(clip.fileName): \(error.localizedDescription)")
            actionError = "Export failed: \(error.localizedDescription)"
        }
    }
}
