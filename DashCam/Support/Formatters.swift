import Foundation

enum Format {
    private static let cardinals = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    static func cardinal(degrees: Double) -> String {
        guard degrees.isFinite, degrees >= 0 else { return "--" }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 22.5).rounded()) % 16
        return cardinals[index]
    }

    static func speedValue(metersPerSecond: Double, unit: SpeedUnit) -> Int {
        guard metersPerSecond.isFinite, metersPerSecond > 0 else { return 0 }
        return Int(unit.convert(metersPerSecond: metersPerSecond).rounded())
    }

    static func heading(degrees: Double) -> String {
        guard degrees.isFinite, degrees >= 0 else { return "--" }
        return "\(cardinal(degrees: degrees)) \(Int(degrees.rounded()))°"
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func coordinate(latitude: Double?, longitude: Double?) -> String {
        guard let latitude, let longitude else { return "--" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    static func clipDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Metres as feet, for field work — nobody paces out a sign in metres.
    static func feet(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        let feet = meters * 3.28084
        return feet < 10
            ? String(format: "%.1f ft", feet)
            : String(format: "%.0f ft", feet)
    }

    /// Compass point for a heading in degrees, e.g. "NNE".
    static func cardinal(_ degrees: Double) -> String {
        guard degrees >= 0 else { return "—" }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return points[Int((degrees / 22.5).rounded()) % 16]
    }

    /// Ride roughness with a severity emoji, e.g. "🟢 0.05g".
    ///
    /// The value is acceleration ABOVE the mount's own resonance, so these
    /// bands describe what the road did, not what the suction-cup arm is
    /// humming at. Green is normal driving including expansion joints and
    /// coarse asphalt; red is reserved for a hit worth reviewing — a deep
    /// pothole, a kerb strike, a collision.
    static func vibration(g: Double?) -> String? {
        guard let g, g.isFinite, g >= 0 else { return nil }
        let emoji: String
        switch g {
        case ..<0.25: emoji = "🟢"
        case ..<0.60: emoji = "🟡"
        case ..<1.10: emoji = "🟠"
        default: emoji = "🔴"
        }
        return String(format: "%@ %.2fg", emoji, g)
    }

    /// Thermal state raw value for the sidecar.
    static func thermalRaw(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    /// Thermal display with emoji, e.g. "❄️ Cool".
    static func thermal(raw: String?) -> String? {
        switch raw {
        case "nominal": return "❄️ Cool"
        case "fair": return "🌡️ Warm"
        case "serious": return "🥵 Hot"
        case "critical": return "🔥 Critical"
        default: return nil
        }
    }
}
