import Foundation

/// Checks that a finished segment's replay data actually reached its sidecar.
///
/// Overlays and telemetry have twice been lost while the live screen looked
/// perfect — a throttle that never reset across segments, and a hand-off that
/// raced the sidecar write. Both compiled, both looked right on the road, and
/// both were only discovered days later when a clip replayed bare. This is the
/// check that makes that failure loud and immediate instead.
enum TelemetryHealth {

    /// What a written sidecar is missing, if anything.
    struct Verdict: Equatable {
        var missingSamples: Bool
        var missingOverlays: Bool

        var isHealthy: Bool { !missingSamples && !missingOverlays }

        /// Driver-facing text; nil when everything is being recorded.
        var warning: String? {
            switch (missingSamples, missingOverlays) {
            case (true, true): return "Telemetry and overlays are not being recorded"
            case (true, false): return "GPS telemetry is not being recorded"
            case (false, true): return "Screen overlays are not being recorded"
            case (false, false): return nil
            }
        }
    }

    /// A segment shorter than this can legitimately hold no data — a 1 Hz
    /// sampler needs a second, and a segment cut short by a stop or the
    /// thermal override may end before the first tick.
    static let minimumMeaningfulDuration: Double = 3.0

    /// Judges one finished segment.
    ///
    /// - Parameters:
    ///   - sampleCount: GPS/motion samples written to the sidecar.
    ///   - overlayCount: overlay snapshots written to the sidecar.
    ///   - duration: the segment's length in seconds.
    ///   - detectionEnabled: false when road detection is switched off, in
    ///     which case having no overlays is the expected, correct outcome.
    static func verdict(
        sampleCount: Int,
        overlayCount: Int,
        duration: Double,
        detectionEnabled: Bool
    ) -> Verdict {
        guard duration >= minimumMeaningfulDuration else {
            return Verdict(missingSamples: false, missingOverlays: false)
        }
        return Verdict(
            missingSamples: sampleCount == 0,
            missingOverlays: detectionEnabled && overlayCount == 0
        )
    }
}
