import XCTest
@testable import DashCam

/// Guards the promise that every clip replays exactly what the driver saw.
///
/// Twice the overlays and telemetry silently stopped reaching the sidecar
/// while the live screen looked perfect, and both times it was only found
/// days later. These tests encode the two failures so they cannot return
/// unnoticed.
final class TelemetryHealthTests: XCTestCase {

    // MARK: - The snapshot throttle (bug 1)

    /// The overlay snapshot throttle compares the segment offset against the
    /// last recorded offset. Segment offsets restart at zero every rotation,
    /// so the throttle has to restart too — left carrying the previous
    /// segment's value it rejects every snapshot for the rest of the drive.
    private struct Throttle {
        var lastSnapshotAt: Double = -1
        static let interval = 0.5

        mutating func beginSegment() { lastSnapshotAt = -1 }

        mutating func accepts(offset: Double) -> Bool {
            guard offset - lastSnapshotAt >= Self.interval else { return false }
            lastSnapshotAt = offset
            return true
        }
    }

    func testSnapshotsAreThrottledWithinASegment() {
        var throttle = Throttle()
        XCTAssertTrue(throttle.accepts(offset: 0))
        XCTAssertFalse(throttle.accepts(offset: 0.2), "Too soon after the last snapshot")
        XCTAssertTrue(throttle.accepts(offset: 0.5))
        XCTAssertTrue(throttle.accepts(offset: 1.0))
    }

    func testSnapshotsResumeOnTheNextSegment() {
        var throttle = Throttle()
        // A full 3-minute segment's worth of snapshots.
        var offset = 0.0
        while offset <= 180 {
            _ = throttle.accepts(offset: offset)
            offset += 1
        }
        XCTAssertGreaterThan(throttle.lastSnapshotAt, 175)

        // Rotation: offsets restart at zero.
        throttle.beginSegment()
        XCTAssertTrue(
            throttle.accepts(offset: 0),
            "Segment 002 onward recorded ZERO overlays because the throttle kept segment 001's offset"
        )
        XCTAssertTrue(throttle.accepts(offset: 1.0))
    }

    func testWithoutTheResetEverySubsequentSnapshotIsRejected() {
        // Proves the original defect, so the reset can never be quietly dropped.
        var throttle = Throttle()
        _ = throttle.accepts(offset: 179)
        // No beginSegment() — this is the bug.
        XCTAssertFalse(throttle.accepts(offset: 0))
        XCTAssertFalse(throttle.accepts(offset: 90))
        XCTAssertFalse(throttle.accepts(offset: 179))
    }

    // MARK: - The written-sidecar health check (bug 2's safety net)

    func testHealthySegmentRaisesNothing() {
        let verdict = TelemetryHealth.verdict(
            sampleCount: 180, overlayCount: 180, duration: 180, detectionEnabled: true
        )
        XCTAssertTrue(verdict.isHealthy)
        XCTAssertNil(verdict.warning)
    }

    func testMissingSamplesAreCaught() {
        // Exactly the state every segment was in after the thermal 4K→HD drop.
        let verdict = TelemetryHealth.verdict(
            sampleCount: 0, overlayCount: 0, duration: 180, detectionEnabled: true
        )
        XCTAssertFalse(verdict.isHealthy)
        XCTAssertEqual(verdict.warning, "Telemetry and overlays are not being recorded")
    }

    func testMissingOverlaysAloneAreCaught() {
        // Exactly the state of segment 002: GPS fine, overlays dead.
        let verdict = TelemetryHealth.verdict(
            sampleCount: 167, overlayCount: 0, duration: 180, detectionEnabled: true
        )
        XCTAssertFalse(verdict.isHealthy)
        XCTAssertEqual(verdict.warning, "Screen overlays are not being recorded")
    }

    func testNoOverlaysIsFineWhenDetectionIsSwitchedOff() {
        let verdict = TelemetryHealth.verdict(
            sampleCount: 180, overlayCount: 0, duration: 180, detectionEnabled: false
        )
        XCTAssertTrue(verdict.isHealthy, "Detection off means no overlays is the correct outcome")
    }

    func testAVeryShortSegmentIsNotFlagged() {
        // A segment cut short by a stop or the thermal override can end
        // before the 1 Hz sampler's first tick. That isn't a fault.
        let verdict = TelemetryHealth.verdict(
            sampleCount: 0, overlayCount: 0, duration: 1.2, detectionEnabled: true
        )
        XCTAssertTrue(verdict.isHealthy)
    }
}
