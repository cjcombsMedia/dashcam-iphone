import XCTest
@testable import DashCam

final class EmergencyLightDetectorTests: XCTestCase {
    private let box = CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.1)

    /// Feeds frames at 5 fps (matching the analyzer cadence).
    private func stats(t: TimeInterval, red: Bool, blue: Bool) -> EmergencyFrameStats {
        EmergencyFrameStats(
            time: t,
            redFraction: red ? 0.01 : 0,
            blueFraction: blue ? 0.01 : 0,
            box: (red || blue) ? box : nil
        )
    }

    func testAlternatingRedBlueStrobesTagOnceWithBox() {
        var detector = EmergencyLightDetector()
        var tags = 0
        var sawBox = false
        // 2 Hz alternating light bar for 3 seconds at 5 fps.
        for i in 0..<15 {
            let t = Double(i) * 0.2
            let phase = (i / 2) % 2 == 0
            let result = detector.process(stats(t: t, red: phase, blue: !phase))
            if result.shouldTag { tags += 1 }
            if result.activeBox != nil { sawBox = true }
        }
        XCTAssertEqual(tags, 1, "One tag per cooldown window")
        XCTAssertTrue(sawBox, "Active detection must expose the box for the overlay")
    }

    func testSteadyBrakeLightsNeverTrigger() {
        var detector = EmergencyLightDetector()
        for i in 0..<50 {
            let result = detector.process(stats(t: Double(i) * 0.2, red: true, blue: false))
            XCTAssertFalse(result.shouldTag)
            XCTAssertNil(result.activeBox)
        }
    }

    func testFlashingRedOnlyTurnSignalNeverTriggers() {
        var detector = EmergencyLightDetector()
        for i in 0..<50 {
            let flashing = (i / 3) % 2 == 0 // ~1.7 Hz blinker
            let result = detector.process(stats(t: Double(i) * 0.2, red: flashing, blue: false))
            XCTAssertFalse(result.shouldTag, "Amber/red-only flashing is a turn signal, not an emergency")
        }
    }

    func testRapidBlueOnlyStrobeTriggers() {
        var detector = EmergencyLightDetector()
        var tagged = false
        for i in 0..<20 {
            let flashing = i % 2 == 0 // 2.5 Hz blue strobe
            if detector.process(stats(t: Double(i) * 0.2, red: false, blue: flashing)).shouldTag {
                tagged = true
            }
        }
        XCTAssertTrue(tagged)
    }

    func testCooldownSuppressesSecondTagUntilElapsed() {
        var detector = EmergencyLightDetector()
        var tagTimes: [TimeInterval] = []
        // Continuous alternating strobes for 70 seconds.
        for i in 0..<350 {
            let t = Double(i) * 0.2
            let phase = (i / 2) % 2 == 0
            if detector.process(stats(t: t, red: phase, blue: !phase)).shouldTag {
                tagTimes.append(t)
            }
        }
        XCTAssertGreaterThanOrEqual(tagTimes.count, 2)
        for (a, b) in zip(tagTimes, tagTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, EmergencyLightDetector.tagCooldown - 0.001)
        }
    }
}
