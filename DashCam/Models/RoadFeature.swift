import Foundation
import SwiftData

/// A remembered road feature — a sign or zone tied to a place and a
/// direction of travel, so it can be shown from memory on later drives even
/// when the camera can't read it (night, glare, rain, or a missed frame).
enum RoadFeatureType: String, Codable, CaseIterable, Identifiable {
    case speedLimit
    case school
    case hump
    case hospital
    case bike
    case city
    case fireStation
    // Regulatory and warning signs, drawn to their MUTCD shapes.
    case stop
    case yield
    case railroad
    case pedestrianCrossing
    case doNotEnter
    case lowClearance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speedLimit: return "Speed limit"
        case .school: return "School zone"
        case .hump: return "Speed hump"
        case .hospital: return "Hospital"
        case .bike: return "Bike route"
        case .city: return "City limits"
        case .fireStation: return "Fire station"
        case .stop: return "Stop sign"
        case .yield: return "Yield"
        case .railroad: return "Railroad crossing"
        case .pedestrianCrossing: return "Pedestrian crossing"
        case .doNotEnter: return "Do not enter"
        case .lowClearance: return "Low clearance"
        }
    }

    var systemImage: String {
        switch self {
        case .speedLimit: return "speedometer"
        case .school: return "figure.walk"
        case .hump: return "arrow.up.and.down"
        case .hospital: return "cross.case.fill"
        case .bike: return "bicycle"
        case .city: return "signpost.right.fill"
        case .fireStation: return "flame.fill"
        case .stop: return "octagon.fill"
        case .yield: return "triangle"
        case .railroad: return "xmark.circle.fill"
        case .pedestrianCrossing: return "figure.walk.motion"
        case .doNotEnter: return "nosign"
        case .lowClearance: return "arrow.up.and.down.square.fill"
        }
    }

    /// How far ahead the feature starts showing, in meters. Zones that need
    /// slowing get more warning than informational signs.
    var triggerDistance: Double {
        switch self {
        case .speedLimit: return 130
        case .school, .hump: return 200
        case .hospital, .fireStation: return 180
        case .bike, .city: return 150
        // You need room to actually stop, so these lead the furthest.
        case .stop, .railroad: return 210
        case .yield, .pedestrianCrossing: return 170
        // A wrong-way warning is only useful right at the mouth of the ramp.
        case .doNotEnter: return 90
        // A truck needs to know before the last exit before the bridge.
        case .lowClearance: return 250
        }
    }

    /// Whether the value field carries a number (speed) for this type.
    var usesNumericValue: Bool {
        switch self {
        case .speedLimit, .school, .hump, .lowClearance: return true
        case .hospital, .bike, .city, .fireStation,
             .stop, .yield, .railroad, .pedestrianCrossing, .doNotEnter: return false
        }
    }
}

enum RoadFeatureSource: String, Codable {
    case detected
    case manual
}

@Model
final class RoadFeature {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    /// Speed for numeric types; city name for `.city`; label for others.
    var value: String?
    var latitude: Double
    var longitude: Double
    /// Compass heading (degrees) of travel when this was captured — a sign
    /// applies to one direction only.
    var heading: Double
    var sourceRaw: String
    /// Sightings so far. A detected feature isn't trusted until it's been
    /// seen twice, so one bad read never sticks.
    var confirmCount: Int
    var createdAt: Date
    var lastSeenAt: Date
    var enabled: Bool

    init(
        id: UUID = UUID(),
        type: RoadFeatureType,
        value: String?,
        latitude: Double,
        longitude: Double,
        heading: Double,
        source: RoadFeatureSource,
        confirmCount: Int = 1,
        createdAt: Date = Date(),
        enabled: Bool = true
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.value = value
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.sourceRaw = source.rawValue
        self.confirmCount = confirmCount
        self.createdAt = createdAt
        self.lastSeenAt = createdAt
        self.enabled = enabled
    }

    var type: RoadFeatureType {
        get { RoadFeatureType(rawValue: typeRaw) ?? .speedLimit }
        set { typeRaw = newValue.rawValue }
    }

    var source: RoadFeatureSource {
        get { RoadFeatureSource(rawValue: sourceRaw) ?? .detected }
        set { sourceRaw = newValue.rawValue }
    }

    /// Manual entries are authoritative — detection never overwrites them,
    /// and they're trusted from the first moment.
    var isTrusted: Bool {
        source == .manual || confirmCount >= 2
    }

    var numericValue: Int? {
        value.flatMap(Int.init)
    }
}
