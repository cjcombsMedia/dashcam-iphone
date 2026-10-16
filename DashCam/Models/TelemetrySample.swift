import Foundation

/// One 1 Hz telemetry sample written to a segment's JSON sidecar.
struct TelemetrySample: Codable, Equatable {
    var timestamp: Date
    var latitude: Double? = nil
    var longitude: Double? = nil
    var altitude: Double? = nil
    var speedMPS: Double? = nil
    var headingDegrees: Double? = nil
    /// Ride roughness in g (decaying accelerometer peak). Optional so older
    /// sidecars still decode.
    var vibrationG: Double? = nil
    /// Thermal state raw value: nominal / fair / serious / critical.
    var thermal: String? = nil
}

/// An emergency-light detection captured during recording: when (seconds
/// into the clip) and where (normalized landscape buffer coordinates), so
/// playback can re-draw the green detection box.
struct EmergencyEvent: Codable, Equatable {
    var offset: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var box: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A traffic-signal display change during recording — evidence of what the
/// light was, whether or not it was shown on screen at the time.
struct SignalEvent: Codable, Equatable {
    var offset: Double
    /// "red" / "yellow" / "green" / "flashingYellow" / "none"
    var state: String
}

/// A snapshot of everything the live screen was showing, recorded ~2×/second
/// so replay and full-graphical exports reproduce the drive exactly.
struct OverlaySnapshot: Codable, Equatable {
    var offset: Double
    var speedLimit: Int?
    var humpShowing: Bool = false
    var humpSpeed: Int?
    var schoolShowing: Bool = false
    var schoolSpeed: Int?
    var hospitalShowing: Bool = false
    var bikeShowing: Bool = false
    var cityName: String?
    var fireStation: String?
    /// Signal state as displayed (nil while the speed gate was closed).
    var signal: String?
    /// "left" / "right" when a cyclist warning was on screen.
    var cyclist: String?
    /// Pedestrian boxes as [x, y, w, h] normalized rects.
    var pedestrians: [[Double]]?
}

/// The JSON document written next to each video segment. Sidecars travel with
/// their segment between LOOP, SAVED, and export.
struct TelemetrySidecar: Codable {
    var segmentFileName: String
    var resolution: String
    var startedAt: Date
    var samples: [TelemetrySample]
    /// Optional so sidecars written before this field existed still decode.
    var emergencyEvents: [EmergencyEvent]? = nil
    var signalEvents: [SignalEvent]? = nil
    var overlaySnapshots: [OverlaySnapshot]? = nil

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
