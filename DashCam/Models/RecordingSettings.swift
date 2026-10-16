import Foundation
import CoreGraphics

/// The two user-selectable capture resolutions. Selected on the main recording
/// screen; locked while recording; applies to the next session.
enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case hd
    case uhd4k

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd: return "HD"
        case .uhd4k: return "4K"
        }
    }

    var dimensions: CGSize {
        switch self {
        case .hd: return CGSize(width: 1920, height: 1080)
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        }
    }

    /// H.264 average bitrate targets (H.264 needs ~30% more bits than HEVC
    /// for the same quality; chosen for maximum player compatibility).
    var videoBitrate: Int {
        switch self {
        case .hd: return 12_000_000
        case .uhd4k: return 50_000_000
        }
    }

    /// Conservative estimate used for storage preflight and capacity readouts.
    /// Video + audio + container overhead.
    var estimatedBytesPerSecond: Int64 {
        Int64((Double(videoBitrate) / 8.0 + 16_000) * 1.08)
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable, Codable {
    case mph
    case kmh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mph: return "mph"
        case .kmh: return "km/h"
        }
    }

    func convert(metersPerSecond: Double) -> Double {
        switch self {
        case .mph: return metersPerSecond * 2.236936
        case .kmh: return metersPerSecond * 3.6
        }
    }
}

enum AutoTagSensitivity: String, CaseIterable, Identifiable, Codable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// Instantaneous user-acceleration magnitude (in g) treated as an impact.
    var impactThresholdG: Double {
        switch self {
        case .low: return 3.5
        case .medium: return 2.5
        case .high: return 1.6
        }
    }

    /// Sustained deceleration magnitude (in g) treated as hard braking.
    var brakingThresholdG: Double {
        switch self {
        case .low: return 0.65
        case .medium: return 0.50
        case .high: return 0.38
        }
    }
}
