import Foundation
import SwiftData

enum TagSource: String, Codable, CaseIterable {
    case manual
    case impact
    case hardBraking
    case emergencyLights

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .impact: return "Impact"
        case .hardBraking: return "Hard braking"
        case .emergencyLights: return "Emergency lights"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "bookmark.fill"
        case .impact: return "burst.fill"
        case .hardBraking: return "exclamationmark.brakesignal"
        case .emergencyLights: return "light.beacon.max.fill"
        }
    }
}

@Model
final class TagMark {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Seconds from the start of the owning clip.
    var offsetInClip: Double
    var latitude: Double?
    var longitude: Double?
    var speedMPS: Double?
    var sourceRaw: String
    var clip: ClipSegment?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        offsetInClip: Double,
        latitude: Double?,
        longitude: Double?,
        speedMPS: Double?,
        source: TagSource
    ) {
        self.id = id
        self.timestamp = timestamp
        self.offsetInClip = offsetInClip
        self.latitude = latitude
        self.longitude = longitude
        self.speedMPS = speedMPS
        self.sourceRaw = source.rawValue
    }

    var source: TagSource {
        TagSource(rawValue: sourceRaw) ?? .manual
    }
}
