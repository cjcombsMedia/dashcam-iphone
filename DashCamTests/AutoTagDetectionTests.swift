import XCTest
@testable import DashCam

final class AutoTagDetectionTests: XCTestCase {
    private func sample(t: TimeInterval, g: Double) -> AccelerationSample {
        AccelerationSample(time: t, x: g, y: 0, z: 0)
    }

    /// The detector now judges values already corrected for the mount's
    /// noise floor. These tests feed a clean signal (floor = 0), so the
    /// excess equals the raw magnitude.
    private func feed(
        _ detector: inout AutoTagDetector, t: TimeInterval, g: Double
    ) -> TagSource? {
        detector.process(sample(t: t, g: g), impactG: g, brakingG: g)
    }

    func testImpactFiresAtThreshold() {
        var detector = AutoTagDetector(sensitivity: .medium)
        XCTAssertEqual(feed(&detector, t: 0, g: 3.0), .impact)
    }

    func testBelowBrakingThresholdNeverFires() {
        var detector = AutoTagDetector(sensitivity: .medium)
        for i in 0..<100 {
            XCTAssertNil(feed(&detector, t: Double(i) * 0.1, g: 0.2))
        }
    }

    func testSensitivityChangesImpactThreshold() {
        var high = AutoTagDetector(sensitivity: .high)
        var medium = AutoTagDetector(sensitivity: .medium)

        // 2.0 g: above high's 1.6, below medium's 2.5.
        XCTAssertEqual(feed(&high, t: 0, g: 2.0), .impact)
        XCTAssertNil(feed(&medium, t: 0, g: 2.0))
    }

    func testSustainedDecelerationFiresHardBraking() {
        var detector = AutoTagDetector(sensitivity: .medium)
        var fired: TagSource?
        for i in 0...10 {
            if let event = feed(&detector, t: Double(i) * 0.1, g: 0.55) {
                fired = event
                break
            }
        }
        XCTAssertEqual(fired, .hardBraking)
    }

    func testBriefBrakingSpikeDoesNotFire() {
        var detector = AutoTagDetector(sensitivity: .medium)
        XCTAssertNil(feed(&detector, t: 0.0, g: 0.55))
        XCTAssertNil(feed(&detector, t: 0.2, g: 0.55))
        // Dropped below threshold before the 0.5 s sustain window elapsed.
        XCTAssertNil(feed(&detector, t: 0.3, g: 0.1))
        XCTAssertNil(feed(&detector, t: 0.4, g: 0.55))
    }

    func testCooldownSuppressesRepeatTriggers() {
        var detector = AutoTagDetector(sensitivity: .medium)
        XCTAssertEqual(feed(&detector, t: 0, g: 3.0), .impact)
        XCTAssertNil(feed(&detector, t: 5, g: 3.0), "Within 10 s cooldown")
        XCTAssertEqual(feed(&detector, t: 11, g: 3.0), .impact)
    }

    func testImpactTakesPriorityOverBraking() {
        var detector = AutoTagDetector(sensitivity: .medium)
        XCTAssertNil(feed(&detector, t: 0.0, g: 0.55))
        XCTAssertEqual(feed(&detector, t: 0.1, g: 4.0), .impact)
    }
}

/// The phone rides a suction cup on a flexible arm, which resonates with
/// the engine and the road surface. Those tests prove the analyzer treats
/// that hum as background and still catches real hits through it.
final class VibrationAnalyzerTests: XCTestCase {
    private let rate = 1.0 / 30.0

    /// A resonating mount: steady oscillation at `amplitude`, no road events.
    /// Matches what the real drives recorded — a median around 0.23 g.
    private func runMount(
        _ analyzer: inout VibrationAnalyzer,
        seconds: Double,
        amplitude: Double,
        hz: Double = 12
    ) {
        let steps = Int(seconds / rate)
        for index in 0..<steps {
            let t = Double(index) * rate
            let magnitude = abs(amplitude * sin(2 * .pi * hz * t))
            analyzer.process(magnitude: magnitude, dt: rate)
        }
    }

    func testMountBuzzSettlesToNearlyZeroReportedRoughness() {
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 30, amplitude: 0.30)

        XCTAssertLessThan(
            analyzer.excess, 0.25,
            "A humming mount must read green, not the orange the owner kept seeing"
        )
        XCTAssertGreaterThan(analyzer.noiseFloor, 0.05, "The floor should have learned the buzz")
    }

    func testWorseMountBuzzStillReadsGreen() {
        // A looser arm, buzzing twice as hard, must not read worse.
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 30, amplitude: 0.60)
        XCTAssertLessThan(analyzer.excess, 0.25)
    }

    func testAPotholeIsStillSeenThroughTheBuzz() {
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 30, amplitude: 0.30)

        // A single sharp hit, as a wheel drops into a pothole.
        let spike = analyzer.process(magnitude: 3.0, dt: rate)
        XCTAssertGreaterThan(spike, 2.5, "A 3 g hit must survive baseline removal")
        XCTAssertGreaterThan(analyzer.excess, 1.10, "and must read red on the overlay")
    }

    func testABriefHitBarelyMovesTheNoiseFloor() {
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 30, amplitude: 0.30)
        let before = analyzer.noiseFloor

        for _ in 0..<3 { analyzer.process(magnitude: 3.0, dt: rate) }

        XCTAssertEqual(analyzer.noiseFloor, before, accuracy: 0.05,
                       "A 100 ms event must not be absorbed as 'normal'")
    }

    func testFloorFallsBackWhenTheRoadSmoothsOut() {
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 40, amplitude: 0.60)
        let rough = analyzer.noiseFloor

        runMount(&analyzer, seconds: 20, amplitude: 0.05)
        XCTAssertLessThan(analyzer.noiseFloor, rough * 0.5,
                          "Once it quietens the floor must follow down, or real hits get masked")
    }

    func testDetectionWaitsForTheFloorToSettle() {
        var analyzer = VibrationAnalyzer()
        XCTAssertFalse(analyzer.isReady, "Judging anything before the floor settles fires false impacts")
        runMount(&analyzer, seconds: 4, amplitude: 0.30)
        XCTAssertTrue(analyzer.isReady)
    }

    func testBrakingSurvivesTheBuzzButVibrationAloneDoesNot() {
        var analyzer = VibrationAnalyzer()
        runMount(&analyzer, seconds: 30, amplitude: 0.30)
        XCTAssertLessThan(analyzer.brakingMagnitude, 0.38,
                          "Mount buzz alone must never reach the braking threshold")

        // A sustained 0.6 g push, as in a hard stop.
        for _ in 0..<Int(1.0 / rate) {
            analyzer.process(magnitude: 0.6, dt: rate)
        }
        XCTAssertGreaterThan(analyzer.brakingMagnitude, 0.38, "A real hard stop must still register")
    }
}

/// The bands the driver actually reads.
final class VibrationDisplayTests: XCTestCase {
    func testNormalDrivingReadsGreen() {
        XCTAssertEqual(Format.vibration(g: 0.05)?.prefix(1), "🟢")
        XCTAssertEqual(Format.vibration(g: 0.20)?.prefix(1), "🟢")
    }

    func testOnlyRealHitsReachRed() {
        XCTAssertEqual(Format.vibration(g: 0.40)?.prefix(1), "🟡")
        XCTAssertEqual(Format.vibration(g: 0.80)?.prefix(1), "🟠")
        XCTAssertEqual(Format.vibration(g: 1.50)?.prefix(1), "🔴")
    }
}
