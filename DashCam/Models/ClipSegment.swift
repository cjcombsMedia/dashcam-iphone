import Foundation
import SwiftData

/// The two on-disk folders. LOOP is overwrite-eligible; SAVED is never
/// auto-deleted by the app.
enum StorageFolder: String, Codable, CaseIterable {
    case loop = "Loop"
    case saved = "Saved"
}

@Model
final class ClipSegment {
    @Attribute(.unique) var id: UUID
    /// File name within its folder (not an absolute path — the app container
    /// path can change between launches).
    var fileName: String
    var folderRaw: String
    var createdAt: Date
    var duration: Double
    var fileSize: Int64
    var resolutionRaw: String
    var sidecarFileName: String?
    /// True once the segment has been remuxed from its crash-safe fragmented
    /// form into a flat fast-start file; the player optimizes-on-open otherwise.
    var isOptimized: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \TagMark.clip)
    var tags: [TagMark]

    init(
        id: UUID = UUID(),
        fileName: String,
        folder: StorageFolder,
        createdAt: Date,
        duration: Double,
        fileSize: Int64,
        resolution: VideoResolution,
        sidecarFileName: String?
    ) {
        self.id = id
        self.fileName = fileName
        self.folderRaw = folder.rawValue
        self.createdAt = createdAt
        self.duration = duration
        self.fileSize = fileSize
        self.resolutionRaw = resolution.rawValue
        self.sidecarFileName = sidecarFileName
        self.tags = []
    }

    var folder: StorageFolder {
        get { StorageFolder(rawValue: folderRaw) ?? .loop }
        set { folderRaw = newValue.rawValue }
    }

    var resolution: VideoResolution {
        VideoResolution(rawValue: resolutionRaw) ?? .hd
    }
}
