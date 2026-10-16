import Foundation
import SwiftData

/// One row per app launch; records when the startup checklist was acknowledged.
@Model
final class SessionLog {
    @Attribute(.unique) var id: UUID
    var launchedAt: Date
    var acknowledgedAt: Date?
    var resolutionRaw: String

    init(id: UUID = UUID(), launchedAt: Date, resolution: VideoResolution) {
        self.id = id
        self.launchedAt = launchedAt
        self.acknowledgedAt = nil
        self.resolutionRaw = resolution.rawValue
    }
}
