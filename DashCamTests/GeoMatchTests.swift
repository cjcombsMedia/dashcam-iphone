import XCTest
@testable import DashCam

final class GeoMatchTests: XCTestCase {
    // A stretch of Old Spanish Trail, Tucson: heading due east (90°).
    private let baseLat = 32.14088
    private let baseLon = -110.76483

    /// ~1 m of longitude at this latitude, for building test points.
    private func offsetEast(_ meters: Double) -> Double {
        baseLon + meters / (111_320 * cos(baseLat * .pi / 180))
    }

    private func offsetNorth(_ meters: Double) -> Double {
        baseLat + meters / 110_574
    }

    // MARK: - Geometry

    func testDistanceIsAccurate() {
        let metres = GeoMatch.distance(
            fromLat: baseLat, fromLon: baseLon,
            toLat: baseLat, toLon: offsetEast(100)
        )
        XCTAssertEqual(metres, 100, accuracy: 2)
    }

    func testBearingDueEast() {
        let bearing = GeoMatch.bearing(
            fromLat: baseLat, fromLon: baseLon,
            toLat: baseLat, toLon: offsetEast(100)
        )
        XCTAssertEqual(bearing, 90, accuracy: 1)
    }

    func testBearingDueNorth() {
        let bearing = GeoMatch.bearing(
            fromLat: baseLat, fromLon: baseLon,
            toLat: offsetNorth(100), toLon: baseLon
        )
        XCTAssertEqual(bearing, 0, accuracy: 1)
    }

    func testHeadingDeltaWrapsAroundNorth() {
        XCTAssertEqual(GeoMatch.headingDelta(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMatch.headingDelta(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(GeoMatch.headingDelta(0, 180), 180, accuracy: 0.001)
    }

    // MARK: - Approach rules

    func testFeatureAheadOnSameHeadingTriggers() {
        XCTAssertTrue(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: baseLat, featureLon: offsetEast(100), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    func testFeatureBehindDoesNotTrigger() {
        // Same road, same direction of travel, but we've already passed it.
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: baseLat, featureLon: offsetEast(-100), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    func testFeatureBeyondTriggerDistanceDoesNotFire() {
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: baseLat, featureLon: offsetEast(400), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    func testOppositeDirectionDoesNotTrigger() {
        // The westbound sign must not fire while driving east.
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: baseLat, featureLon: offsetEast(100), featureHeading: 270,
            triggerDistance: 130
        ))
    }

    func testSlightHeadingDifferenceStillTriggers() {
        // Curving road: 25° off is still the same direction of travel.
        XCTAssertTrue(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: baseLat, featureLon: offsetEast(80), featureHeading: 115,
            triggerDistance: 130
        ))
    }

    func testVeryCloseFeatureTriggersRegardlessOfBearingNoise() {
        // Within a few metres the bearing is meaningless; treat as arrived.
        XCTAssertTrue(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(10), featureLon: baseLon, featureHeading: 90,
            triggerDistance: 130
        ))
    }

    // MARK: - The parallel-street corridor

    /// The reported bug: driving the street one block over from the main
    /// road set off its signs. The feature is ahead and on the same heading,
    /// so only the perpendicular offset can rule it out.
    func testSignOnAParallelStreetOneBlockOverStaysQuiet() {
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(90), featureLon: offsetEast(100), featureHeading: 90,
            triggerDistance: 130
        ), "A sign 90 m to the side is on another street, however far ahead it is")
    }

    func testSignOnANarrowlyParallelStreetStaysQuiet() {
        // Even a close parallel service road, 45 m off.
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(45), featureLon: offsetEast(100), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    func testSignAcrossAWideRoadStillTriggers() {
        // Opposite side of a divided highway — 15 m off your lane is still
        // your road, and must keep working.
        XCTAssertTrue(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(15), featureLon: offsetEast(100), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    func testCorridorHoldsAtFullTriggerRange() {
        // At the far edge of the trigger range the corridor must not fan out.
        XCTAssertTrue(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(10), featureLon: offsetEast(195), featureHeading: 90,
            triggerDistance: 200
        ))
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: 90,
            featureLat: offsetNorth(40), featureLon: offsetEast(195), featureHeading: 90,
            triggerDistance: 200
        ), "200 m out, a 40 m offset is still another street")
    }

    func testLateralOffsetMath() {
        XCTAssertEqual(GeoMatch.lateralOffset(distance: 100, offAxisDegrees: 0), 0, accuracy: 0.001)
        XCTAssertEqual(GeoMatch.lateralOffset(distance: 100, offAxisDegrees: 90), 100, accuracy: 0.001)
        XCTAssertEqual(GeoMatch.lateralOffset(distance: 100, offAxisDegrees: 30), 50, accuracy: 0.01)
    }

    func testUnknownHeadingNeverTriggers() {
        XCTAssertFalse(GeoMatch.isApproaching(
            currentLat: baseLat, currentLon: baseLon, currentHeading: -1,
            featureLat: baseLat, featureLon: offsetEast(100), featureHeading: 90,
            triggerDistance: 130
        ))
    }

    // MARK: - Dedupe

    func testNearbySameDirectionSightingIsTheSameFeature() {
        XCTAssertTrue(GeoMatch.isSameFeature(
            existingLat: baseLat, existingLon: baseLon, existingHeading: 90,
            newLat: baseLat, newLon: offsetEast(40), newHeading: 95
        ))
    }

    func testOppositeDirectionSightingIsADifferentFeature() {
        // Same pole, other side of the road: a different sign entirely.
        XCTAssertFalse(GeoMatch.isSameFeature(
            existingLat: baseLat, existingLon: baseLon, existingHeading: 90,
            newLat: baseLat, newLon: offsetEast(10), newHeading: 270
        ))
    }

    func testDistantSightingIsADifferentFeature() {
        XCTAssertFalse(GeoMatch.isSameFeature(
            existingLat: baseLat, existingLon: baseLon, existingHeading: 90,
            newLat: baseLat, newLon: offsetEast(300), newHeading: 90
        ))
    }
}
