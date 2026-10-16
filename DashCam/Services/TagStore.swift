import Foundation
import SwiftData

/// A tag captured while its segment is still being written. Applied to the
/// SwiftData store when the segment file finalizes.
struct PendingTag {
    var timestamp: Date
    var offsetInClip: Double
    var latitude: Double?
    var longitude: Double?
    var speedMPS: Double?
    var source: TagSource
}

/// Creates tags and enforces the rule that tagging MOVES a segment (plus its
/// telemetry sidecar) from LOOP to SAVED.
@MainActor
final class TagStore {
    private let storage: StorageManager

    init(storage: StorageManager) {
        self.storage = storage
    }

    /// Registers a finished segment in the library. Segments that collected
    /// tags while recording land directly in SAVED.
    @discardableResult
    func registerSegment(
        result: CaptureService.SegmentResult,
        sidecarFileName: String?,
        pendingTags: [PendingTag],
        context: ModelContext
    ) -> ClipSegment {
        let clip = ClipSegment(
            fileName: result.fileName,
            folder: .loop,
            createdAt: result.startedAt,
            duration: result.duration,
            fileSize: result.fileSize,
            resolution: result.resolution,
            sidecarFileName: sidecarFileName
        )
        context.insert(clip)

        for pending in pendingTags {
            // A tag placed in the final moments of a segment can carry an
            // offset slightly past the encoded duration; clamp so timeline
            // markers always land on the scrubber.
            let offset = result.duration > 0
                ? min(pending.offsetInClip, result.duration)
                : pending.offsetInClip
            let tag = TagMark(
                timestamp: pending.timestamp,
                offsetInClip: offset,
                latitude: pending.latitude,
                longitude: pending.longitude,
                speedMPS: pending.speedMPS,
                source: pending.source
            )
            context.insert(tag)
            tag.clip = clip
        }

        if !pendingTags.isEmpty {
            try? saveToProtected(clip)
        }
        try? context.save()
        return clip
    }

    /// Moves a LOOP clip and its sidecar to the protected SAVED folder.
    func saveToProtected(_ clip: ClipSegment) throws {
        guard clip.folder == .loop else { return }
        try storage.moveToSaved(fileName: clip.fileName, sidecarFileName: clip.sidecarFileName)
        clip.folder = .saved
    }

    func delete(_ clip: ClipSegment, context: ModelContext) throws {
        try storage.delete(
            fileName: clip.fileName,
            sidecarFileName: clip.sidecarFileName,
            from: clip.folder
        )
        context.delete(clip)
        try? context.save()
    }

    func videoURL(for clip: ClipSegment) -> URL {
        storage.url(forFileName: clip.fileName, in: clip.folder)
    }
}
