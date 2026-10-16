import Foundation

// MARK: - Telemetry (mirrors the sidecars the phone writes)

public struct TelemetrySample: Codable, Sendable {
    public var timestamp: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var speedMPS: Double?
    public var headingDegrees: Double?
    public var vibrationG: Double?
    public var thermal: String?
}

/// What the phone displayed on screen, sampled twice a second.
public struct OverlaySnapshot: Codable, Sendable {
    public var offset: Double
    public var speedLimit: Int?
    public var humpShowing: Bool?
    public var humpSpeed: Int?
    public var schoolShowing: Bool?
    public var schoolSpeed: Int?
    public var hospitalShowing: Bool?
    public var bikeShowing: Bool?
    public var cityName: String?
    public var fireStation: String?
    public var signal: String?
    public var cyclist: String?
    public var pedestrians: [[Double]]?
}

public struct SignalEvent: Codable, Sendable {
    public var offset: Double
    public var state: String
}

public struct EmergencyEvent: Codable, Sendable {
    public var offset: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct TelemetrySidecar: Codable, Sendable {
    public var segmentFileName: String
    public var resolution: String
    public var startedAt: Date
    public var samples: [TelemetrySample]
    public var overlaySnapshots: [OverlaySnapshot]?
    public var signalEvents: [SignalEvent]?
    public var emergencyEvents: [EmergencyEvent]?

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The sample nearest a given offset into the clip — how a label drawn
    /// at 00:42 learns where in the world it was.
    public func sample(atOffset offset: Double) -> TelemetrySample? {
        guard !samples.isEmpty else { return nil }
        return samples.min { a, b in
            abs(a.timestamp.timeIntervalSince(startedAt) - offset)
                < abs(b.timestamp.timeIntervalSince(startedAt) - offset)
        }
    }

    /// What was on the phone's screen at this instant. Screens are sampled
    /// twice a second, so the most recent one at or before the playhead is
    /// what the driver was actually looking at — carried forward up to
    /// `holdFor` so a sign doesn't flicker between samples, but no further
    /// (otherwise the last screen of a clip would hang there forever).
    public func screen(atOffset offset: Double, holdFor: Double = 1.0) -> OverlaySnapshot? {
        guard let snapshots = overlaySnapshots, !snapshots.isEmpty else { return nil }
        guard let latest = snapshots.last(where: { $0.offset <= offset + 0.001 }) else { return nil }
        return offset - latest.offset <= holdFor ? latest : nil
    }

    /// The emergency-light box the phone had drawn at this instant, as
    /// [x, y, width, height] in unit coordinates.
    public func emergencyBox(atOffset offset: Double, within: Double = 0.75) -> [Double]? {
        guard let events = emergencyEvents, !events.isEmpty else { return nil }
        guard let event = events.min(by: {
            abs($0.offset - offset) < abs($1.offset - offset)
        }), abs(event.offset - offset) <= within else { return nil }
        return [event.x, event.y, event.width, event.height]
    }
}

// MARK: - Label classes (data-driven so new obstacles need no rebuild)

/// Where a sign is used. Signage is national — an octagon means stop in both
/// countries, but "ALTO" and "CUOTA" only exist south of the border, and the
/// interstate shield only exists north of it.
public enum SignRegion: String, Codable, Hashable, Sendable, CaseIterable {
    case unitedStates = "us"
    case mexico = "mx"
    /// Used in both countries, or not country-specific at all (a pothole).
    case both

    public var label: String {
        switch self {
        case .unitedStates: return "USA"
        case .mexico: return "Mexico"
        case .both: return "Both"
        }
    }

    public var flag: String {
        switch self {
        case .unitedStates: return "🇺🇸"
        case .mexico: return "🇲🇽"
        case .both: return "🌎"
        }
    }

    /// True when this class should be offered while labelling `country`.
    public func applies(to country: SignRegion) -> Bool {
        self == .both || country == .both || self == country
    }
}

public struct LabelClass: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Machine name used in the training dataset, e.g. "construction_bollard".
    public var name: String
    public var display: String
    /// Hex colour for the box.
    public var color: String
    public var group: String
    /// Maps to a phone road-memory type when this class is a geo feature.
    public var memoryType: String?
    /// True when the label carries a value (a speed number, a city name).
    public var hasValue: Bool
    /// Which country's signage this belongs to.
    public var region: SignRegion

    public init(
        name: String, display: String, color: String, group: String,
        memoryType: String? = nil, hasValue: Bool = false,
        region: SignRegion = .both
    ) {
        self.name = name
        self.display = display
        self.color = color
        self.group = group
        self.memoryType = memoryType
        self.hasValue = hasValue
        self.region = region
    }

    /// Decoded leniently: a classes.json written before regions existed has
    /// no `region` key, and must keep working rather than wiping the user's
    /// customised class list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        display = try container.decode(String.self, forKey: .display)
        color = try container.decode(String.self, forKey: .color)
        group = try container.decode(String.self, forKey: .group)
        memoryType = try container.decodeIfPresent(String.self, forKey: .memoryType)
        hasValue = try container.decodeIfPresent(Bool.self, forKey: .hasValue) ?? false
        region = try container.decodeIfPresent(SignRegion.self, forKey: .region) ?? .both
    }
}

public enum DefaultClasses {
    public static let all: [LabelClass] = [
        // Regulatory / warning signs
        .init(name: "speed_limit", display: "Speed limit", color: "#FFFFFF", group: "Signs",
              memoryType: "speedLimit", hasValue: true),
        .init(name: "school_sign", display: "School zone", color: "#CFFF1B", group: "Signs",
              memoryType: "school", hasValue: true),
        .init(name: "hump_sign", display: "Speed hump", color: "#FFD400", group: "Signs",
              memoryType: "hump", hasValue: true),
        .init(name: "hospital_sign", display: "Hospital", color: "#0047BB", group: "Signs",
              memoryType: "hospital"),
        .init(name: "bike_route_sign", display: "Bike route", color: "#00733B", group: "Signs",
              memoryType: "bike"),
        .init(name: "city_limit_sign", display: "City limits", color: "#00733B", group: "Signs",
              memoryType: "city", hasValue: true),
        .init(name: "fire_station_sign", display: "Fire station", color: "#C70D0D", group: "Signs",
              memoryType: "fireStation", hasValue: true),
        .init(name: "stop_sign", display: "Stop", color: "#C70D0D", group: "Signs"),
        .init(name: "yield_sign", display: "Yield", color: "#E8442B", group: "Signs"),
        .init(name: "do_not_pass_sign", display: "Do not pass", color: "#EDEDED", group: "Signs"),
        .init(name: "crossing_sign", display: "Crossing", color: "#FFD400", group: "Signs"),
        .init(name: "railroad_sign", display: "Railroad", color: "#FFD400", group: "Signs"),

        // Signals
        .init(name: "signal_red", display: "Signal — red", color: "#FF3B30", group: "Signals"),
        .init(name: "signal_yellow", display: "Signal — yellow", color: "#FFCC00", group: "Signals"),
        .init(name: "signal_green", display: "Signal — green", color: "#34C759", group: "Signals"),
        .init(name: "signal_arrow", display: "Signal — arrow", color: "#FF9F0A", group: "Signals"),
        .init(name: "signal_housing", display: "Signal housing", color: "#8E8E93", group: "Signals"),

        // Road users
        .init(name: "cyclist", display: "Cyclist", color: "#30D158", group: "Road users"),
        .init(name: "pedestrian", display: "Pedestrian", color: "#64D2FF", group: "Road users"),
        .init(name: "motorcycle", display: "Motorcycle", color: "#BF5AF2", group: "Road users"),
        .init(name: "vehicle", display: "Vehicle", color: "#0A84FF", group: "Road users"),
        .init(name: "emergency_vehicle", display: "Emergency vehicle", color: "#FF375F", group: "Road users"),
        .init(name: "emergency_lights", display: "Emergency lights", color: "#FF2D55", group: "Road users"),

        // Obstacles / work zones
        .init(name: "construction_bollard", display: "Bollard", color: "#FF9500", group: "Obstacles"),
        .init(name: "traffic_cone", display: "Cone", color: "#FF6B00", group: "Obstacles"),
        .init(name: "barrier", display: "Barrier / barricade", color: "#FF9500", group: "Obstacles"),
        .init(name: "construction_sign", display: "Construction sign", color: "#FF9500", group: "Obstacles"),
        .init(name: "work_vehicle", display: "Work vehicle", color: "#FFB340", group: "Obstacles"),
        .init(name: "debris", display: "Debris in road", color: "#FF453A", group: "Obstacles"),
        .init(name: "pothole", display: "Pothole", color: "#AC8E68", group: "Obstacles"),
        .init(name: "animal", display: "Animal", color: "#D2B48C", group: "Obstacles"),

        // Painted surface features — the green bike lane, crosswalks
        .init(name: "bike_lane_paint", display: "Bike lane paint (green)", color: "#00C853", group: "Surface"),
        .init(name: "crosswalk_paint", display: "Crosswalk markings", color: "#F2F2F7", group: "Surface"),
        .init(name: "stop_line", display: "Stop line", color: "#F2F2F7", group: "Surface"),
        .init(name: "speed_hump_marking", display: "Speed hump markings", color: "#FFD400", group: "Surface"),
        .init(name: "lane_arrow", display: "Lane arrow", color: "#F2F2F7", group: "Surface"),

        // MARK: Guide signs — the green panels that say where the road goes
        .init(name: "exit_panel", display: "Exit panel (green)", color: "#006B54", group: "Guide",
              hasValue: true, region: .unitedStates),
        .init(name: "exit_number_tab", display: "Exit number tab", color: "#006B54", group: "Guide",
              hasValue: true, region: .unitedStates),
        .init(name: "destination_sign", display: "Destination / distance", color: "#006B54", group: "Guide",
              hasValue: true),
        .init(name: "street_name_sign", display: "Street name", color: "#006B54", group: "Guide",
              hasValue: true),
        .init(name: "mileage_sign", display: "Mileage panel", color: "#006B54", group: "Guide"),
        .init(name: "salida_panel", display: "Salida (exit)", color: "#006B54", group: "Guide",
              hasValue: true, region: .mexico),

        // MARK: Route markers — the shield tells you what kind of road it is
        .init(name: "interstate_shield", display: "Interstate shield", color: "#003F87", group: "Routes",
              hasValue: true, region: .unitedStates),
        .init(name: "us_route_shield", display: "US route shield", color: "#FFFFFF", group: "Routes",
              hasValue: true, region: .unitedStates),
        .init(name: "state_route_shield", display: "State route shield", color: "#FFFFFF", group: "Routes",
              hasValue: true, region: .unitedStates),
        .init(name: "business_route_shield", display: "Business route", color: "#00733B", group: "Routes",
              hasValue: true, region: .unitedStates),
        .init(name: "county_route_shield", display: "County route", color: "#F5C518", group: "Routes",
              hasValue: true, region: .unitedStates),
        .init(name: "toll_road_sign", display: "Toll road", color: "#F5C518", group: "Routes",
              region: .unitedStates),
        .init(name: "toll_booth_sign", display: "Toll booth / plaza", color: "#F5C518", group: "Routes"),
        .init(name: "express_lane_sign", display: "Express / HOV lane", color: "#8E44AD", group: "Routes",
              region: .unitedStates),
        .init(name: "direction_banner", display: "Direction banner (N/S/E/W)", color: "#006B54",
              group: "Routes", hasValue: true),
        .init(name: "mex_federal_shield", display: "Federal highway (MEX)", color: "#FFFFFF",
              group: "Routes", hasValue: true, region: .mexico),
        .init(name: "mex_state_shield", display: "State highway (MEX)", color: "#FFFFFF",
              group: "Routes", hasValue: true, region: .mexico),
        .init(name: "cuota_sign", display: "Cuota (toll road)", color: "#F5C518", group: "Routes",
              region: .mexico),
        .init(name: "libre_sign", display: "Libre (free road)", color: "#00733B", group: "Routes",
              region: .mexico),

        // MARK: Services — the big blue panels
        .init(name: "services_panel", display: "Services panel (blue)", color: "#003F87", group: "Services",
              hasValue: true),
        .init(name: "gas_sign", display: "Gas / fuel", color: "#003F87", group: "Services"),
        .init(name: "food_sign", display: "Food", color: "#003F87", group: "Services"),
        .init(name: "lodging_sign", display: "Lodging", color: "#003F87", group: "Services"),
        .init(name: "rest_area_sign", display: "Rest area", color: "#003F87", group: "Services"),
        .init(name: "camping_sign", display: "Camping", color: "#003F87", group: "Services"),
        .init(name: "ev_charging_sign", display: "EV charging", color: "#003F87", group: "Services"),
        .init(name: "weigh_station_sign", display: "Weigh station", color: "#003F87", group: "Services",
              region: .unitedStates),

        // MARK: Landmarks — brown means somewhere worth stopping
        .init(name: "landmark_sign", display: "Landmark panel (brown)", color: "#614126",
              group: "Landmarks", hasValue: true),
        .init(name: "national_park_sign", display: "National / state park", color: "#614126",
              group: "Landmarks"),
        .init(name: "museum_sign", display: "Museum / heritage centre", color: "#614126",
              group: "Landmarks"),
        .init(name: "historic_site_sign", display: "Historic site", color: "#614126",
              group: "Landmarks"),
        .init(name: "recreation_sign", display: "Recreation area", color: "#614126",
              group: "Landmarks"),
        .init(name: "scenic_overlook_sign", display: "Scenic overlook", color: "#614126",
              group: "Landmarks"),
        .init(name: "zona_arqueologica_sign", display: "Zona arqueológica", color: "#614126",
              group: "Landmarks", region: .mexico),

        // MARK: Lane and clearance warnings
        .init(name: "merge_sign", display: "Merge", color: "#FFD400", group: "Lane & clearance"),
        .init(name: "added_lane_sign", display: "Added lane", color: "#FFD400", group: "Lane & clearance"),
        .init(name: "lane_ends_sign", display: "Lane ends", color: "#FFD400", group: "Lane & clearance"),
        .init(name: "lane_shift_sign", display: "Lane shift", color: "#FFD400", group: "Lane & clearance"),
        .init(name: "speed_reduced_sign", display: "Speed reduced ahead", color: "#FFD400",
              group: "Lane & clearance"),
        .init(name: "bridge_clearance_sign", display: "Bridge clearance", color: "#006B54",
              group: "Lane & clearance", memoryType: "lowClearance", hasValue: true),
        .init(name: "weight_limit_sign", display: "Weight limit", color: "#FFFFFF",
              group: "Lane & clearance", hasValue: true),
        .init(name: "narrow_bridge_sign", display: "Narrow bridge", color: "#FFD400",
              group: "Lane & clearance"),

        // MARK: More regulatory signs
        .init(name: "do_not_enter_sign", display: "Do not enter", color: "#C70D0D", group: "Signs",
              memoryType: "doNotEnter"),
        .init(name: "wrong_way_sign", display: "Wrong way", color: "#C70D0D", group: "Signs",
              memoryType: "doNotEnter"),
        .init(name: "no_turn_on_red_sign", display: "No turn on red", color: "#FFFFFF", group: "Signs",
              region: .unitedStates),
        .init(name: "one_way_sign", display: "One way", color: "#1C1C1E", group: "Signs"),
        .init(name: "keep_right_sign", display: "Keep right / left", color: "#1C1C1E", group: "Signs"),
        .init(name: "pedestrian_crossing_sign", display: "Pedestrian crossing", color: "#CFFF1B",
              group: "Signs", memoryType: "pedestrianCrossing"),
        .init(name: "curve_warning_sign", display: "Curve / turn", color: "#FFD400", group: "Signs"),
        .init(name: "signal_ahead_sign", display: "Signal ahead", color: "#FFD400", group: "Signs"),
        .init(name: "stop_ahead_sign", display: "Stop ahead", color: "#FFD400", group: "Signs"),

        // MARK: Mexican signage
        .init(name: "alto_sign", display: "ALTO (stop)", color: "#C70D0D", group: "Signs",
              memoryType: "stop", region: .mexico),
        .init(name: "ceda_el_paso_sign", display: "CEDA EL PASO (yield)", color: "#C70D0D",
              group: "Signs", memoryType: "yield", region: .mexico),
        .init(name: "velocidad_maxima_sign", display: "VELOCIDAD MÁXIMA (km/h)", color: "#FFFFFF",
              group: "Signs", memoryType: "speedLimit", hasValue: true, region: .mexico),
        .init(name: "tope_sign", display: "TOPE (speed hump)", color: "#FFD400", group: "Signs",
              memoryType: "hump", region: .mexico),
        .init(name: "no_rebase_sign", display: "NO REBASE (no passing)", color: "#FFFFFF",
              group: "Signs", region: .mexico),
        .init(name: "escuela_sign", display: "ESCUELA (school)", color: "#CFFF1B", group: "Signs",
              memoryType: "school", region: .mexico),
        .init(name: "retorno_sign", display: "RETORNO (U-turn)", color: "#006B54", group: "Signs",
              region: .mexico),
        .init(name: "curva_peligrosa_sign", display: "CURVA PELIGROSA", color: "#FFD400",
              group: "Signs", region: .mexico),
        .init(name: "altura_libre_sign", display: "ALTURA LIBRE (clearance)", color: "#FFFFFF",
              group: "Lane & clearance", memoryType: "lowClearance", hasValue: true, region: .mexico),

        // MARK: Transit & parking — urban signage, mostly pictograms on blue
        .init(name: "bus_stop_sign", display: "Bus stop", color: "#0067B1", group: "Transit"),
        .init(name: "bus_lane_sign", display: "Bus lane", color: "#0067B1", group: "Transit"),
        .init(name: "brt_station_sign", display: "BRT / Metrobús station", color: "#0067B1",
              group: "Transit", region: .mexico),
        .init(name: "taxi_stand_sign", display: "Taxi stand / Sitio", color: "#0067B1", group: "Transit"),
        .init(name: "metro_station_sign", display: "Metro / subway", color: "#F5820A", group: "Transit"),
        .init(name: "tram_station_sign", display: "Tram / light rail", color: "#0067B1", group: "Transit"),
        .init(name: "train_station_sign", display: "Train station", color: "#0067B1", group: "Transit"),
        .init(name: "airport_sign", display: "Airport", color: "#0067B1", group: "Transit"),
        .init(name: "bike_share_sign", display: "Bike share", color: "#0067B1", group: "Transit"),
        .init(name: "school_bus_stop_sign", display: "School bus stop ahead", color: "#FFD400",
              group: "Transit", region: .unitedStates),
        .init(name: "parking_sign", display: "Parking (P)", color: "#0067B1", group: "Transit",
              region: .unitedStates),
        .init(name: "estacionamiento_sign", display: "Estacionamiento (E)", color: "#0067B1",
              group: "Transit", region: .mexico),
        .init(name: "no_parking_sign", display: "No parking", color: "#C70D0D", group: "Transit",
              region: .unitedStates),
        .init(name: "no_estacionarse_sign", display: "No estacionarse (E tachada)", color: "#C70D0D",
              group: "Transit", region: .mexico),
        .init(name: "tow_away_sign", display: "Tow away zone / Grúa", color: "#C70D0D", group: "Transit"),
        .init(name: "disabled_parking_sign", display: "Disabled parking", color: "#0067B1",
              group: "Transit"),
        .init(name: "loading_zone_sign", display: "Loading zone", color: "#0067B1", group: "Transit"),
        .init(name: "pedestrian_zone_sign", display: "Pedestrian zone", color: "#0067B1",
              group: "Transit"),

        // MARK: Advertising — labelled so the detector learns to ignore it
        .init(name: "billboard", display: "Billboard (ignore)", color: "#8E8E93", group: "Ignore"),
        .init(name: "business_sign", display: "Business sign (ignore)", color: "#8E8E93", group: "Ignore"),
    ]
}

// MARK: - Labels

/// One drawn box on one frame. Rect is normalized (0–1), top-left origin.
public struct FrameLabel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    public var className: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var value: String?
    public var note: String?

    public init(
        id: UUID = UUID(), time: Double, className: String,
        x: Double, y: Double, width: Double, height: Double,
        value: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.time = time
        self.className = className
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.value = value
        self.note = note
    }
}

public struct ClipLabels: Codable, Sendable {
    public var clipFileName: String
    public var labels: [FrameLabel]

    public init(clipFileName: String, labels: [FrameLabel] = []) {
        self.clipFileName = clipFileName
        self.labels = labels
    }
}

// MARK: - Reviewing what the phone detected

/// One thing the phone showed on screen during the drive, reconstructed
/// from the sidecar so it can be confirmed, corrected, or rejected.
public struct PhoneDetection: Identifiable, Hashable, Sendable {
    public var id: String
    public var time: Double
    /// Matches a LabelClass name where one exists.
    public var className: String
    public var display: String
    public var value: String?
    /// Present for detections the phone boxed (emergency lights, people).
    public var box: [Double]?

    public init(
        id: String, time: Double, className: String,
        display: String, value: String? = nil, box: [Double]? = nil
    ) {
        self.id = id
        self.time = time
        self.className = className
        self.display = display
        self.value = value
        self.box = box
    }
}

public enum DetectionVerdict: String, Codable, Sendable {
    case confirmed
    case rejected
    case corrected
}

public struct DetectionReview: Codable, Sendable {
    public var detectionID: String
    public var verdict: DetectionVerdict
    public var className: String
    public var value: String?
    public var time: Double
    public var reviewedAt: Date

    public init(
        detectionID: String, verdict: DetectionVerdict, className: String,
        value: String?, time: Double, reviewedAt: Date = Date()
    ) {
        self.detectionID = detectionID
        self.verdict = verdict
        self.className = className
        self.value = value
        self.time = time
        self.reviewedAt = reviewedAt
    }
}

public struct ClipReview: Codable, Sendable {
    public var clipFileName: String
    public var reviews: [DetectionReview]

    public init(clipFileName: String, reviews: [DetectionReview] = []) {
        self.clipFileName = clipFileName
        self.reviews = reviews
    }
}

// MARK: - Road memory export (what the phone imports)

public struct RoadFeatureExport: Codable, Sendable {
    public var type: String
    public var value: String?
    public var latitude: Double
    public var longitude: Double
    public var heading: Double
    public var source: String

    public init(
        type: String, value: String?, latitude: Double,
        longitude: Double, heading: Double, source: String = "manual"
    ) {
        self.type = type
        self.value = value
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.source = source
    }
}

public struct RoadMemoryExport: Codable, Sendable {
    public var version: Int
    public var generatedAt: Date
    public var features: [RoadFeatureExport]

    public init(features: [RoadFeatureExport], generatedAt: Date = Date()) {
        self.version = 1
        self.generatedAt = generatedAt
        self.features = features
    }
}
