import XCTest
@testable import DashCam

final class RoadTextParserTests: XCTestCase {
    func testSpeedLimitAcrossLines() {
        let signs = RoadTextParser.parse(["SPEED", "LIMIT", "45"])
        XCTAssertTrue(signs.contains(.speedLimit(45)))
    }

    func testSpeedLimitSingleLine() {
        XCTAssertTrue(RoadTextParser.parse(["Speed Limit 25"]).contains(.speedLimit(25)))
    }

    func testUnreasonableSpeedRejected() {
        XCTAssertTrue(RoadTextParser.parse(["SPEED LIMIT 99"]).isEmpty)
    }

    func testSpeedHumpWithSpeed() {
        let signs = RoadTextParser.parse(["SPEED HUMP", "15 MPH"])
        XCTAssertTrue(signs.contains(.speedHump(mph: 15)))
    }

    func testBumpVariantWithoutSpeed() {
        XCTAssertTrue(RoadTextParser.parse(["BUMPS AHEAD"]).contains(.speedHump(mph: nil)))
    }

    func testBikeRoute() {
        XCTAssertTrue(RoadTextParser.parse(["BIKE ROUTE"]).contains(.bikeLane))
        XCTAssertTrue(RoadTextParser.parse(["BIKE", "LANE"]).contains(.bikeLane))
    }

    func testHospitalStandaloneH() {
        XCTAssertTrue(RoadTextParser.parse(["H"]).contains(.hospital))
        XCTAssertTrue(RoadTextParser.parse(["HOSPITAL", "NEXT RIGHT"]).contains(.hospital))
    }

    func testHInsideWordIsNotHospital() {
        XCTAssertFalse(RoadTextParser.parse(["HOUGHTON RD"]).contains(.hospital))
    }

    func testOrdinaryStreetTextYieldsNothing() {
        XCTAssertTrue(RoadTextParser.parse(["GOLF LINKS RD", "DO NOT PASS"]).isEmpty)
    }

    func testSchoolCrossingPlain() {
        XCTAssertTrue(RoadTextParser.parse(["SCHOOL", "XING"]).contains(.schoolCrossing(mph: nil)))
    }

    func testSchoolInSessionPlacardWithSpeed() {
        let signs = RoadTextParser.parse(["NO PASSING", "15 MPH", "FINED DOUBLE", "SCHOOL IN SESSION"])
        XCTAssertTrue(signs.contains(.schoolCrossing(mph: 15)))
    }

    func testHospitalWithArrowNoise() {
        XCTAssertTrue(RoadTextParser.parse(["H →"]).contains(.hospital))
    }

    func testCityEntryWithCityLimits() {
        let signs = RoadTextParser.parse(["WELCOME", "TUCSON", "CITY LIMITS"])
        XCTAssertTrue(signs.contains(.cityEntry("Tucson")))
    }

    func testCityEntryWithTo() {
        XCTAssertTrue(RoadTextParser.parse(["WELCOME TO PHOENIX"]).contains(.cityEntry("Phoenix")))
    }

    func testFireStationWithNumber() {
        XCTAssertTrue(RoadTextParser.parse(["FIRE STATION 17"]).contains(.fireStation(number: "17")))
    }

    func testFireStationWithoutNumber() {
        XCTAssertTrue(RoadTextParser.parse(["FIRE STATION"]).contains(.fireStation(number: nil)))
    }

    func testWelcomeAloneYieldsNoCity() {
        let signs = RoadTextParser.parse(["WELCOME", "CITY LIMITS"])
        XCTAssertFalse(signs.contains(where: { if case .cityEntry = $0 { return true } else { return false } }))
    }
}

final class SignalStateMachineTests: XCTestCase {
    private func obs(
        red: Bool = false, yellow: Bool = false, green: Bool = false, flashing: Bool = false
    ) -> SignalObservation {
        SignalObservation(red: red, yellow: yellow, green: green, flashingYellow: flashing)
    }

    func testRedShowsUntilGreen() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(red: true)), .red)
        // Red stays even when momentarily unseen.
        XCTAssertEqual(machine.process(now: 5, observation: obs()), .red)
        XCTAssertEqual(machine.process(now: 8, observation: obs(green: true)), .green)
    }

    func testYellowShowsUntilRed() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(yellow: true)), .yellow)
        XCTAssertEqual(machine.process(now: 2, observation: obs(red: true)), .red)
    }

    func testGreenHidesAfter25Seconds() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(green: true)), .green)
        XCTAssertEqual(machine.process(now: 24, observation: obs(green: true)), .green)
        XCTAssertNil(machine.process(now: 26, observation: obs(green: true)))
    }

    func testFlashingYellowHides3SecondsAfterLost() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(flashing: true)), .flashingYellow)
        XCTAssertEqual(machine.process(now: 2, observation: obs()), .flashingYellow)
        XCTAssertNil(machine.process(now: 3.5, observation: obs()))
    }

    func testRedClearsWhenStale() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(red: true)), .red)
        // Drove away without ever seeing green: clears after the stale window.
        XCTAssertNil(machine.process(now: 16, observation: obs()))
    }

    func testRedTakesPriorityOverGreenOnFreshDisplay() {
        var machine = SignalStateMachine()
        XCTAssertEqual(machine.process(now: 0, observation: obs(red: true, green: true)), .red)
    }
}

/// US regulatory signs. Their legends are short, standard words, so OCR
/// reads them reliably — but short words also appear on trucks, shopfronts
/// and bumper stickers, so matching has to be whole-word.
final class RegulatorySignParsingTests: XCTestCase {
    func testStopSignIsRead() {
        XCTAssertTrue(RoadTextParser.parse(["STOP"]).contains(.stop))
    }

    func testYieldIsRead() {
        XCTAssertTrue(RoadTextParser.parse(["YIELD"]).contains(.yield))
    }

    func testWordsContainingStopDoNotFire() {
        // The back of a bus, a shopfront, a bumper sticker.
        XCTAssertFalse(RoadTextParser.parse(["BUS STOPPING"]).contains(.stop))
        XCTAssertFalse(RoadTextParser.parse(["NONSTOP"]).contains(.stop))
        XCTAssertFalse(RoadTextParser.parse(["YIELDING"]).contains(.yield))
    }

    func testWrongWayAndDoNotEnterBothMeanDoNotEnter() {
        XCTAssertTrue(RoadTextParser.parse(["DO NOT ENTER"]).contains(.doNotEnter))
        XCTAssertTrue(RoadTextParser.parse(["WRONG WAY"]).contains(.doNotEnter))
    }

    func testRailroadLegendsAreRead() {
        XCTAssertTrue(RoadTextParser.parse(["RAILROAD CROSSING"]).contains(.railroad))
        XCTAssertTrue(RoadTextParser.parse(["RR XING"]).contains(.railroad))
    }

    func testPedestrianCrossingIsRead() {
        XCTAssertTrue(RoadTextParser.parse(["PED XING"]).contains(.pedestrianCrossing))
        XCTAssertTrue(RoadTextParser.parse(["PEDESTRIAN CROSSING"]).contains(.pedestrianCrossing))
    }

    func testEachRegulatorySignMapsToARememberedType() {
        XCTAssertEqual(RoadSign.stop.featureType, .stop)
        XCTAssertEqual(RoadSign.yield.featureType, .yield)
        XCTAssertEqual(RoadSign.railroad.featureType, .railroad)
        XCTAssertEqual(RoadSign.pedestrianCrossing.featureType, .pedestrianCrossing)
        XCTAssertEqual(RoadSign.doNotEnter.featureType, .doNotEnter)
        XCTAssertNil(RoadSign.speedLimit(45).featureType, "Value-carrying signs are remembered separately")
    }

    /// Stopping distance matters: a stop sign has to appear before you're
    /// on top of it.
    func testStopAndRailroadLeadFurthestOfAllSigns() {
        let stop = RoadFeatureType.stop.triggerDistance
        XCTAssertGreaterThanOrEqual(stop, RoadFeatureType.speedLimit.triggerDistance)
        XCTAssertGreaterThanOrEqual(RoadFeatureType.railroad.triggerDistance, stop * 0.9)
        XCTAssertLessThan(
            RoadFeatureType.doNotEnter.triggerDistance, stop,
            "A wrong-way warning is only meaningful at the mouth of the ramp"
        )
    }
}
