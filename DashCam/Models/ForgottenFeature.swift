import Foundation
import SwiftData

/// A record that a remembered sign was deliberately removed.
///
/// Deleting the feature alone isn't enough. The Mac holds its own copy of
/// road memory, and the next import would hand the sign straight back — the
/// phone would forget it and immediately relearn it, and the driver would
/// long-press the same wrong sign forever.
///
/// So a removal leaves a tombstone behind. The phone refuses to re-import
/// anything matching one, and the tombstone is pushed to DashCam Studio so
/// its exports stop including that sign at source.
@Model
final class ForgottenFeature {
    var id: UUID
    var typeRaw: String
    var latitude: Double
    var longitude: Double
    var heading: Double
    var createdAt: Date
    /// False until DashCam Studio has acknowledged it.
    var syncedToDesktop: Bool

    init(
        type: RoadFeatureType,
        latitude: Double,
        longitude: Double,
        heading: Double,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.createdAt = createdAt
        self.syncedToDesktop = false
    }

    var type: RoadFeatureType? { RoadFeatureType(rawValue: typeRaw) }

    /// True when an incoming feature is the sign this tombstone buried —
    /// same kind, same place, same direction of travel.
    func buries(type: RoadFeatureType, latitude: Double, longitude: Double, heading: Double) -> Bool {
        guard self.type == type else { return false }
        return GeoMatch.isSameFeature(
            existingLat: self.latitude, existingLon: self.longitude,
            existingHeading: self.heading,
            newLat: latitude, newLon: longitude, newHeading: heading
        )
    }
}

/// Wire format shared with DashCam Studio.
struct ForgottenFeatureExport: Codable {
    var type: String
    var latitude: Double
    var longitude: Double
    var heading: Double
    var forgottenAt: Date
}

/// What the phone tells DashCam Studio after acting on an export. Mirrors
/// `PhoneReport` in DashCamKit.
struct PhoneSyncReport: Codable {
    var at: Date
    var deviceName: String
    var appVersion: String
    var featuresHeld: Int
    var imported: Int
    var skippedAlreadyKnown: Int
    var refusedForgotten: Int
    var unsupported: Int
    var tombstones: Int
}
