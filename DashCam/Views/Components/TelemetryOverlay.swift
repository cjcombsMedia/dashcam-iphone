import SwiftUI

/// Satellite fix indicator for the speed readout.
struct GPSFixIndicator: View {
    var quality: GPSFixQuality
    var night: Bool

    private var color: Color {
        switch quality {
        case .none: return .red
        case .poor: return .yellow
        case .good: return night ? .orange : .green
        }
    }

    var body: some View {
        Label(quality.label, systemImage: "antenna.radiowaves.left.and.right")
            .font(.caption2.bold())
            .foregroundStyle(color)
            .accessibilityLabel(quality.label)
    }
}

/// The gray telemetry box: big speed, heading, coordinates, GPS state, and
/// time. Shared by the live recording screen and clip replay so both look
/// identical.
struct TelemetryBox: View {
    var speedMPS: Double
    var headingDegrees: Double
    var latitude: Double?
    var longitude: Double?
    var fix: GPSFixQuality
    var unit: SpeedUnit
    var night: Bool
    /// nil shows a live wall clock; a value shows that moment (replay).
    var timestamp: Date?
    /// Ride roughness in g; hidden when nil.
    var vibrationG: Double? = nil
    /// Thermal state raw value (nominal/fair/serious/critical); hidden when nil.
    var thermalRaw: String? = nil

    private var primaryColor: Color { night ? .orange : .white }
    private var secondaryColor: Color { night ? .orange.opacity(0.7) : .white.opacity(0.75) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Format.speedValue(metersPerSecond: speedMPS, unit: unit))")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(unit.label)
                    .font(.title3.bold())
                    .foregroundStyle(secondaryColor)
                if night {
                    Image(systemName: "moon.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Night processing active")
                }
            }
            Text(Format.heading(degrees: headingDegrees))
                .font(.title2.bold())
                .monospacedDigit()
            Text(Format.coordinate(latitude: latitude, longitude: longitude))
                .font(.caption.monospaced())
                .foregroundStyle(secondaryColor)
            HStack(spacing: 10) {
                GPSFixIndicator(quality: fix, night: night)
                clock
            }
            if Format.vibration(g: vibrationG) != nil || Format.thermal(raw: thermalRaw) != nil {
                HStack(spacing: 10) {
                    if let vibration = Format.vibration(g: vibrationG) {
                        Text(vibration)
                    }
                    if let thermal = Format.thermal(raw: thermalRaw) {
                        Text(thermal)
                    }
                }
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(secondaryColor)
            }
        }
        .foregroundStyle(primaryColor)
        .shadow(color: .black.opacity(0.8), radius: 3)
        .padding(12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var clock: some View {
        if let timestamp {
            Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(secondaryColor)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(secondaryColor)
            }
        }
    }
}

/// Live telemetry overlay for the full recording preview.
struct TelemetryOverlay: View {
    @ObservedObject var location: LocationService
    var unit: SpeedUnit
    var night: Bool
    /// Gyro+magnetometer fused heading used when compass/GPS have none.
    var fallbackHeading: Double?
    var vibrationG: Double? = nil
    var thermalRaw: String? = nil

    var body: some View {
        TelemetryBox(
            speedMPS: location.speedMPS,
            headingDegrees: location.headingDegrees >= 0 ? location.headingDegrees : (fallbackHeading ?? -1),
            latitude: location.latitude,
            longitude: location.longitude,
            fix: location.fixQuality,
            unit: unit,
            night: night,
            timestamp: nil,
            vibrationG: vibrationG,
            thermalRaw: thermalRaw
        )
    }
}
