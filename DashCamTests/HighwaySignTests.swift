import XCTest
@testable import DashCam

/// Parsed against the exact legends photographed on I-10 south of Phoenix,
/// plus the two billboards standing beside them.
final class BillboardFilterTests: XCTestCase {

    /// The "Sweet James" injury-attorney billboard. Everything about it reads
    /// like a road sign to OCR: huge, high-contrast, all-caps.
    func testInjuryAttorneyBillboardProducesNoRoadSigns() {
        let lines = ["ACCIDENT OR INJURY?", "SweetJames", "800-900-0000", "PROUD PARTNER"]
        XCTAssertTrue(RoadTextParser.parse(lines).isEmpty,
                      "A billboard must never produce a road sign")

        // The ad markers are stripped; a bare brand name has no marker to
        // catch it by, and doesn't need one — it matches no sign legend, so
        // it parses to nothing. The bar is "produces no signs", not
        // "recognised as an advert", because only the former can hurt.
        let survivors = BillboardFilter.roadworthy(lines)
        XCTAssertFalse(survivors.contains("ACCIDENT OR INJURY?"))
        XCTAssertFalse(survivors.contains("800-900-0000"))
        XCTAssertFalse(survivors.contains("PROUD PARTNER"))
    }

    /// The jewellery billboard: brand name, services, phone numbers.
    func testRetailBillboardIsRejected() {
        let lines = [
            "FINE JEWELRY", "SERVICE & REPAIRS", "CUSTOM DESIGN",
            "PRECIOUS ELEMENTS", "480-000-0000",
        ]
        XCTAssertTrue(RoadTextParser.parse(lines).isEmpty)
    }

    func testPhoneNumbersAndWebAddressesAreTheGiveaway() {
        XCTAssertTrue(BillboardFilter.isAdvertising("CALL 555-123-4567"))
        XCTAssertTrue(BillboardFilter.isAdvertising("WWW.EXAMPLE.COM"))
        XCTAssertTrue(BillboardFilter.isAdvertising("50% OFF"))
        XCTAssertTrue(BillboardFilter.isAdvertising("OPEN 24 HOURS"))
    }

    /// The important half: a billboard beside a real sign must not suppress
    /// the real sign. Filtering is per line, not per frame.
    func testARealSignBesideABillboardStillParses() {
        let lines = ["ACCIDENT OR INJURY?", "800-900-0000", "EXIT 164", "Queen Creek Rd", "2 MILES"]
        let signs = RoadTextParser.parse(lines)
        XCTAssertTrue(signs.contains { if case .exit = $0 { return true }; return false },
                      "The exit panel must survive the billboard next to it")
    }

    func testOrdinaryRoadLegendsAreNeverTreatedAsAdvertising() {
        for legend in ["SPEED LIMIT 45", "EXIT 164", "Queen Creek Rd", "WEST 10",
                       "15 FT 9 IN", "Maricopa", "Huhugam Heritage Center", "STOP"] {
            XCTAssertFalse(BillboardFilter.isAdvertising(legend), "\(legend) is a road sign")
        }
    }
}

final class HighwaySignParserTests: XCTestCase {

    // MARK: Bridge clearance

    func testTheUnderpassClearanceSignIsRead() {
        let clearance = HighwaySignParser.parseClearance("15 FT 9 IN")
        XCTAssertEqual(clearance, Clearance(feet: 15, inches: 9))
        XCTAssertEqual(clearance?.totalInches, 189)
    }

    func testClearanceInFeetAloneIsRead() {
        XCTAssertEqual(HighwaySignParser.parseClearance("13 FT"), Clearance(feet: 13, inches: 0))
    }

    func testAbsurdClearancesAreRejected() {
        XCTAssertNil(HighwaySignParser.parseClearance("99 FT 9 IN"))
        XCTAssertNil(HighwaySignParser.parseClearance("2 FT"))
    }

    func testMexicanClearanceInMetresConverts() {
        // 4.5 m ≈ 14 ft 9 in.
        let clearance = HighwaySignParser.parseClearance("ALTURA LIBRE 4.5 M")
        XCTAssertEqual(clearance?.feet, 14)
        XCTAssertEqual(clearance?.inches ?? 0, 9, accuracy: 1)
    }

    func testAClearanceBelowVehicleHeightIsTheOneThatMatters() {
        let posted = Clearance(feet: 12, inches: 6)      // 150 in
        let boxTruck = 13 * 12                            // 156 in
        XCTAssertLessThan(posted.totalInches, boxTruck)
    }

    // MARK: Exits

    func testTheQueenCreekExitPanelIsRead() {
        let signs = RoadTextParser.parse(["EXIT 164", "347", "SOUTH", "Queen Creek Rd", "2 MILES"])
        guard case .exit(let info)? = signs.first(where: { if case .exit = $0 { return true }; return false }) else {
            return XCTFail("No exit parsed")
        }
        XCTAssertEqual(info.number, "164")
        XCTAssertEqual(info.destination, "Queen Creek Rd")
        XCTAssertEqual(info.milesAway ?? 0, 2, accuracy: 0.01)
    }

    func testTheOneMileVersionOfTheSamePanelIsRead() {
        let signs = RoadTextParser.parse(["EXIT 164", "347", "SOUTH", "Queen Creek Rd", "1 MILE"])
        guard case .exit(let info)? = signs.first(where: { if case .exit = $0 { return true }; return false }) else {
            return XCTFail("No exit parsed")
        }
        XCTAssertEqual(info.milesAway ?? 0, 1, accuracy: 0.01)
    }

    func testAFractionalDistanceIsRead() {
        // "Chandler Blvd 1¼ MILES"
        let signs = RoadTextParser.parse(["EXIT 160", "Chandler Blvd", "1¼ MILES"])
        guard case .exit(let info)? = signs.first(where: { if case .exit = $0 { return true }; return false }) else {
            return XCTFail("No exit parsed")
        }
        XCTAssertEqual(info.milesAway ?? 0, 1.25, accuracy: 0.01)
    }

    func testAnExitWithLetterSuffixIsRead() {
        let signs = RoadTextParser.parse(["EXIT 164B", "Wild Horse Pass Blvd"])
        guard case .exit(let info)? = signs.first(where: { if case .exit = $0 { return true }; return false }) else {
            return XCTFail("No exit parsed")
        }
        XCTAssertEqual(info.number, "164B")
    }

    // MARK: Route shields

    func testTheInterstateShieldIsRead() {
        let signs = RoadTextParser.parse(["WEST", "10"])
        guard case .route(let shield, let number, let direction)? =
                signs.first(where: { if case .route = $0 { return true }; return false }) else {
            return XCTFail("No route parsed")
        }
        XCTAssertEqual(number, "10")
        XCTAssertEqual(direction, "WEST")
        XCTAssertEqual(shield, .state, "A bare number with a direction is a state-route shield")
    }

    func testAnExplicitInterstateNumberIsRead() {
        guard case .route(let shield, let number, _)? = HighwaySignParser.parseRoute("I-10 WEST") else {
            return XCTFail("No route parsed")
        }
        XCTAssertEqual(shield, .interstate)
        XCTAssertEqual(number, "10")
    }

    func testAMexicanFederalRouteIsRead() {
        guard case .route(let shield, let number, _)? = HighwaySignParser.parseRoute("MEX 15D NORTE") else {
            return XCTFail("No route parsed")
        }
        XCTAssertEqual(shield, .mexicoFederal)
        XCTAssertEqual(number, "15D")
    }

    // MARK: Services and landmarks

    func testTheBlueServicesPanelIsRead() {
        let signs = RoadTextParser.parse(["EXIT 162", "FOOD", "GAS"])
        guard case .services(let kinds)? =
                signs.first(where: { if case .services = $0 { return true }; return false }) else {
            return XCTFail("No services parsed")
        }
        XCTAssertTrue(kinds.contains(.food))
        XCTAssertTrue(kinds.contains(.gas))
    }

    /// The brand names on that panel are not road data — they must not leak
    /// through as a destination or a landmark.
    func testBrandNamesOnTheServicesPanelAreNotLandmarks() {
        let signs = RoadTextParser.parse(["EXIT 162", "FOOD", "GAS", "Arby's", "McDonald's", "Love's"])
        XCTAssertFalse(signs.contains { if case .landmark = $0 { return true }; return false })
    }

    func testTheBrownLandmarkPanelIsRead() {
        let signs = RoadTextParser.parse(["EXIT 164", "Maricopa", "Huhugam Heritage Center"])
        guard case .landmark(let name)? =
                signs.first(where: { if case .landmark = $0 { return true }; return false }) else {
            return XCTFail("No landmark parsed")
        }
        XCTAssertTrue(name.contains("Heritage"))
    }

    // MARK: Speed reduced

    func testSpeedReducedAheadIsAWarningNotALimit() {
        let signs = RoadTextParser.parse(["SPEED", "REDUCED", "AHEAD"])
        XCTAssertTrue(signs.contains(.speedReducedAhead))
        XCTAssertFalse(signs.contains { if case .speedLimit = $0 { return true }; return false },
                       "It posts no number — it must not set a speed limit")
    }
}

/// Mexican signage. The dangerous case is a km/h limit read as mph.
final class MexicanSignTests: XCTestCase {

    func testVelocidadMaximaIsConvertedFromKmhToMph() {
        let signs = RoadTextParser.parse(["VELOCIDAD MAXIMA", "80"])
        // 80 km/h ≈ 50 mph. Showing "80" would be a 30 mph error.
        XCTAssertTrue(signs.contains(.speedLimit(50)))
        XCTAssertFalse(signs.contains(.speedLimit(80)))
    }

    func testAKmhSuffixAlsoConverts() {
        XCTAssertTrue(RoadTextParser.parse(["100 KM/H"]).contains(.speedLimit(62)))
    }

    func testAltoIsAStopSign() {
        XCTAssertTrue(RoadTextParser.parse(["ALTO"]).contains(.stop))
    }

    func testCedaElPasoIsAYield() {
        XCTAssertTrue(RoadTextParser.parse(["CEDA EL PASO"]).contains(.yield))
    }

    func testTopesAreSpeedHumps() {
        XCTAssertTrue(RoadTextParser.parse(["TOPES"]).contains(.speedHump(mph: nil)))
    }

    func testPostedSpeedConversionIsCorrect() {
        XCTAssertEqual(PostedSpeed(value: 80, isMetric: true).mph, 50)
        XCTAssertEqual(PostedSpeed(value: 45, isMetric: false).mph, 45)
        XCTAssertEqual(PostedSpeed(value: 80, isMetric: true).label, "80 km/h")
    }
}

/// Urban signage. The freeway service panels (gas, food, lodging) are a rural
/// vocabulary — in a city the blue panels mean transit and parking instead.
final class UrbanSignTests: XCTestCase {

    func testBusStopIsReadInBothLanguages() {
        for legend in ["BUS STOP", "PARADA"] {
            guard case .services(let kinds)? = RoadTextParser.parse([legend])
                    .first(where: { if case .services = $0 { return true }; return false }) else {
                return XCTFail("\(legend) produced no service sign")
            }
            XCTAssertTrue(kinds.contains(.busStop))
        }
    }

    func testTaxiAndMetroAreRead() {
        XCTAssertTrue(serviceKinds(["SITIO DE TAXIS"]).contains(.taxi))
        XCTAssertTrue(serviceKinds(["METRO"]).contains(.metro))
        XCTAssertTrue(serviceKinds(["METROBUS"]).contains(.metro))
    }

    /// The dangerous one: "NO ESTACIONARSE" contains no standalone
    /// "ESTACIONAMIENTO", but a sloppy match would still read a prohibition
    /// as an invitation to park.
    func testNoParkingIsNeverReadAsParking() {
        let prohibited = serviceKinds(["NO ESTACIONARSE"])
        XCTAssertTrue(prohibited.contains(.noParking))
        XCTAssertFalse(prohibited.contains(.parking))

        let alsoProhibited = serviceKinds(["PROHIBIDO ESTACIONARSE"])
        XCTAssertTrue(alsoProhibited.contains(.noParking))
        XCTAssertFalse(alsoProhibited.contains(.parking),
                       "A prohibition must never be shown as available parking")
    }

    func testPlainParkingStillReads() {
        XCTAssertTrue(serviceKinds(["ESTACIONAMIENTO"]).contains(.parking))
        XCTAssertTrue(serviceKinds(["PARKING"]).contains(.parking))
    }

    func testHighwayServicesStillWorkAlongsideTheUrbanOnes() {
        let kinds = serviceKinds(["FOOD", "GAS"])
        XCTAssertTrue(kinds.contains(.food))
        XCTAssertTrue(kinds.contains(.gas))
        XCTAssertFalse(kinds.contains(.busStop))
    }

    private func serviceKinds(_ lines: [String]) -> Set<ServiceKind> {
        for sign in RoadTextParser.parse(lines) {
            if case .services(let kinds) = sign { return kinds }
        }
        return []
    }
}
