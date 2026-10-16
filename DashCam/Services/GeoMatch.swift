import Foundation

/// Pure geodesic helpers for road-feature memory. No CoreLocation types, so
/// every rule here is unit-testable with plain numbers.
enum GeoMatch {
    /// How far a stored heading may differ from current travel and still be
    /// considered the same direction of travel (degrees).
    static let headingTolerance: Double = 50
    /// A feature must be roughly ahead, not behind or beside (degrees off
    /// the current heading).
    static let aheadTolerance: Double = 65
    /// How far a feature may sit to the SIDE of your line of travel and
    /// still count as being on your road (meters).
    ///
    /// This is what keeps a sign on the main street quiet while you drive
    /// the street parallel to it. An angle-only test can't do that: a sign
    /// 130 m ahead and 90 m to the left is still only 35° off your heading,
    /// so it passes an "is it ahead of me" check while being a block away.
    /// Measuring the perpendicular offset instead makes the trigger a narrow
    /// corridor along your path rather than a wide cone.
    ///
    /// 20 m covers a wide multi-lane road plus GPS scatter; the nearest
    /// parallel street is virtually always further off than that.
    static let maxLateralOffset: Double = 20
    /// Below this range bearing is too noisy to judge, so proximity alone
    /// counts as arriving at the feature.
    static let atFeatureRadius: Double = 12
    /// Two detections this close, of the same type and direction, are the
    /// same real-world sign (meters).
    static let dedupeRadius: Double = 70

    private static let earthRadius: Double = 6_371_000

    /// Great-circle distance in meters.
    static func distance(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double
    ) -> Double {
        let phi1 = fromLat * .pi / 180
        let phi2 = toLat * .pi / 180
        let deltaPhi = (toLat - fromLat) * .pi / 180
        let deltaLambda = (toLon - fromLon) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing in degrees (0–360) from one point toward another.
    static func bearing(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double
    ) -> Double {
        let phi1 = fromLat * .pi / 180
        let phi2 = toLat * .pi / 180
        let deltaLambda = (toLon - fromLon) * .pi / 180

        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees.truncatingRemainder(dividingBy: 360) < 0
            ? degrees.truncatingRemainder(dividingBy: 360) + 360
            : degrees.truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute angle between two compass headings (0–180).
    static func headingDelta(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta
    }

    /// True when travelling `heading` from a point means this feature is
    /// approaching: same direction of travel, still ahead, and within range.
    ///
    /// The "ahead" test is what stops a sign re-firing once it's behind you.
    static func isApproaching(
        currentLat: Double, currentLon: Double, currentHeading: Double,
        featureLat: Double, featureLon: Double, featureHeading: Double,
        triggerDistance: Double
    ) -> Bool {
        guard currentHeading >= 0 else { return false }
        guard headingDelta(currentHeading, featureHeading) <= headingTolerance else { return false }

        let metres = distance(
            fromLat: currentLat, fromLon: currentLon,
            toLat: featureLat, toLon: featureLon
        )
        guard metres <= triggerDistance else { return false }

        // Very close by: treat as "at" the feature regardless of bearing
        // noise, which is unreliable at short range.
        if metres < atFeatureRadius { return true }

        let toFeature = bearing(
            fromLat: currentLat, fromLon: currentLon,
            toLat: featureLat, toLon: featureLon
        )
        let offAxis = headingDelta(currentHeading, toFeature)
        guard offAxis <= aheadTolerance else { return false }

        // The corridor test: how far off your line of travel does this sit?
        return lateralOffset(distance: metres, offAxisDegrees: offAxis) <= maxLateralOffset
    }

    /// Perpendicular distance from your line of travel to a point that is
    /// `distance` away at `offAxisDegrees` off your heading.
    static func lateralOffset(distance: Double, offAxisDegrees: Double) -> Double {
        abs(distance * sin(offAxisDegrees * .pi / 180))
    }

    /// True when a new sighting refers to the same real-world sign as one
    /// already stored (same place, same direction).
    static func isSameFeature(
        existingLat: Double, existingLon: Double, existingHeading: Double,
        newLat: Double, newLon: Double, newHeading: Double
    ) -> Bool {
        guard headingDelta(existingHeading, newHeading) <= headingTolerance else { return false }
        return distance(
            fromLat: existingLat, fromLon: existingLon,
            toLat: newLat, toLon: newLon
        ) <= dedupeRadius
    }
}
