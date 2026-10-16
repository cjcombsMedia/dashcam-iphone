import Foundation

// MARK: - Highway sign vocabulary

/// Which shield a route number is carried on. The shape tells you what kind
/// of road it is before you read the number.
enum RouteShield: String, Codable, Equatable {
    /// Blue-and-red interstate shield.
    case interstate
    /// White US-route shield.
    case usHighway
    /// State route — shape varies by state; Arizona uses a cut-corner square.
    case state
    /// Mexican federal highway.
    case mexicoFederal

    var label: String {
        switch self {
        case .interstate: return "I"
        case .usHighway: return "US"
        case .state: return "SR"
        case .mexicoFederal: return "MEX"
        }
    }
}

/// Services advertised on the big blue exit panels.
enum ServiceKind: String, Codable, Equatable, CaseIterable {
    case gas, food, lodging, camping, hospital, rest
    // Urban services. A blue panel in a city means transit, not fuel.
    case busStop, taxi, metro, parking, noParking

    var label: String {
        switch self {
        case .gas: return "GAS"
        case .food: return "FOOD"
        case .lodging: return "LODGING"
        case .camping: return "CAMPING"
        case .hospital: return "HOSPITAL"
        case .rest: return "REST AREA"
        case .busStop: return "BUS STOP"
        case .taxi: return "TAXI"
        case .metro: return "METRO"
        case .parking: return "PARKING"
        case .noParking: return "NO PARKING"
        }
    }

    var systemImage: String {
        switch self {
        case .gas: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .lodging: return "bed.double.fill"
        case .camping: return "tent.fill"
        case .hospital: return "cross.case.fill"
        case .rest: return "figure.walk"
        case .busStop: return "bus.fill"
        case .taxi: return "car.fill"
        case .metro: return "tram.fill"
        case .parking: return "parkingsign"
        case .noParking: return "parkingsign.slash"
        }
    }
}

/// The lane-change warnings carried on yellow diamonds.
enum MergeKind: String, Codable, Equatable {
    case merge
    case addedLane
    case laneEnds

    var label: String {
        switch self {
        case .merge: return "MERGE"
        case .addedLane: return "LANE ADDS"
        case .laneEnds: return "LANE ENDS"
        }
    }
}

/// A speed value with the unit it was posted in — Mexican signs are km/h and
/// showing "80" from a Mexican sign as mph would be dangerously wrong.
struct PostedSpeed: Equatable {
    var value: Int
    var isMetric: Bool

    var label: String { isMetric ? "\(value) km/h" : "\(value)" }

    /// Converted to mph for comparison against the car's speed.
    var mph: Int {
        isMetric ? Int((Double(value) * 0.621371).rounded()) : value
    }
}

/// Overhead clearance, as posted: feet and inches in the US, metres in Mexico.
struct Clearance: Equatable {
    var feet: Int
    var inches: Int

    var totalInches: Int { feet * 12 + inches }
    var label: String { inches > 0 ? "\(feet)'\(inches)\"" : "\(feet)'" }

    /// Metres, for a sign posted in Mexico.
    static func fromMetres(_ metres: Double) -> Clearance {
        let totalInches = Int((metres * 39.3701).rounded())
        return Clearance(feet: totalInches / 12, inches: totalInches % 12)
    }
}

/// One exit, as read from a green guide panel.
struct ExitInfo: Equatable {
    var number: String?
    var destination: String?
    /// How far ahead, in miles, when the panel says so.
    var milesAway: Double?
}

// MARK: - Billboards

/// Keeps advertising out of the sign pipeline.
///
/// A billboard is the single most common large, high-contrast, text-covered
/// rectangle on an American highway, and OCR reads it just as happily as a
/// guide sign. Left alone it produces phantom exits, phantom towns and
/// phantom speed limits from phone numbers and ad copy.
///
/// Road signs use a closed, austere vocabulary: place names, route numbers,
/// distances, and a short list of legends. Advertising does the opposite —
/// it needs to be contacted, so it carries a phone number, a web address, a
/// price, or a sales pitch. Those are the tells.
enum BillboardFilter {
    /// Text that only ever appears on advertising.
    private static let adPhrases = [
        "CALL", "FREE", "SALE", "OPEN 24", "WWW", ".COM", ".NET", ".ORG",
        "ACCIDENT OR INJURY", "ATTORNEY", "LAWYER", "INJURY", "CASINO",
        "NOW HIRING", "COMING SOON", "FOR LEASE", "FOR SALE", "ADVERTISE",
        "PROUD PARTNER", "%", "$",
    ]

    /// True when this line is advertising rather than a road sign.
    static func isAdvertising(_ line: String) -> Bool {
        let text = line.uppercased()

        // A phone number is the giveaway. Nothing on a road sign has one.
        if text.firstMatch(of: /\d{3}[-.\s]\d{3}[-.\s]\d{4}/) != nil { return true }
        if text.firstMatch(of: /\b(800|833|844|855|866|877|888)\b/) != nil { return true }

        return adPhrases.contains { text.contains($0) }
    }

    /// Drops advertising lines, keeping everything else for sign parsing.
    ///
    /// Filtering per line rather than per frame matters: a billboard beside a
    /// real exit sign must not suppress the exit sign too.
    static func roadworthy(_ lines: [String]) -> [String] {
        lines.filter { !isAdvertising($0) }
    }
}

// MARK: - Highway sign parsing

/// Parses the guide, service and route signs that dominate freeway driving.
/// Pure text logic, unit-tested against the real legends.
enum HighwaySignParser {

    static func parse(_ lines: [String]) -> [RoadSign] {
        let clean = BillboardFilter.roadworthy(lines)
        guard !clean.isEmpty else { return [] }
        let joined = clean.joined(separator: " ").uppercased()

        var signs: [RoadSign] = []
        if let clearance = parseClearance(joined) { signs.append(.bridgeClearance(clearance)) }
        if let exit = parseExit(clean, joined: joined) { signs.append(.exit(exit)) }
        if let route = parseRoute(joined) { signs.append(route) }
        signs.append(contentsOf: parseServices(joined))
        if let landmark = parseLandmark(clean, joined: joined) { signs.append(.landmark(landmark)) }
        if parseSpeedReduced(joined) { signs.append(.speedReducedAhead) }
        return signs
    }

    // MARK: Bridge clearance

    /// "15 FT 9 IN", "13'6\"", or a Mexican "4.5 M" panel.
    static func parseClearance(_ text: String) -> Clearance? {
        if let match = text.firstMatch(of: /(\d{1,2})\s*(?:FT|FEET|')\s*(\d{1,2})\s*(?:IN|INCHES|")/),
           let feet = Int(match.1), let inches = Int(match.2),
           (7...20).contains(feet), (0...11).contains(inches) {
            return Clearance(feet: feet, inches: inches)
        }
        if let match = text.firstMatch(of: /(\d{1,2})\s*(?:FT|FEET|')(?!\d)/),
           let feet = Int(match.1), (7...20).contains(feet) {
            return Clearance(feet: feet, inches: 0)
        }
        // Mexico posts clearance in metres: "ALTURA LIBRE 4.5 M".
        if let match = text.firstMatch(of: /(\d{1,2}[.,]\d{1,2})\s*M\b/),
           let metres = Double(String(match.1).replacingOccurrences(of: ",", with: ".")),
           (2.0...7.0).contains(metres) {
            return Clearance.fromMetres(metres)
        }
        return nil
    }

    // MARK: Exits

    /// "EXIT 164 / 347 SOUTH / Queen Creek Rd / 2 MILES".
    static func parseExit(_ lines: [String], joined: String) -> ExitInfo? {
        // Mexican equivalent is "SALIDA".
        let hasExitWord = joined.firstMatch(of: /\bEXIT\b/) != nil
            || joined.firstMatch(of: /\bSALIDA\b/) != nil
        var number: String?
        if let match = joined.firstMatch(of: /\b(?:EXIT|SALIDA)\s+(\d{1,3}[A-C]?)\b/) {
            number = String(match.1)
        }
        guard hasExitWord else { return nil }

        var miles: Double?
        if let match = joined.firstMatch(of: /(\d+)\s*(?:¼|1\/4)\s*MILES?/), let whole = Double(match.1) {
            miles = whole + 0.25
        } else if let match = joined.firstMatch(of: /(\d+)\s*(?:½|1\/2)\s*MILES?/), let whole = Double(match.1) {
            miles = whole + 0.5
        } else if let match = joined.firstMatch(of: /\b(\d{1,2})\s*MILES?\b/), let whole = Double(match.1) {
            miles = whole
        } else if let match = joined.firstMatch(of: /\b(\d{1,2})\s*KM\b/), let km = Double(match.1) {
            miles = km * 0.621371
        }

        // The destination is the longest line that isn't the EXIT tab, a
        // distance, or a bare route number.
        let destination = lines
            .filter { line in
                let text = line.uppercased()
                guard text.count >= 4 else { return false }
                if text.contains("EXIT") || text.contains("SALIDA") { return false }
                if text.firstMatch(of: /^\s*\d+\s*(MILES?|KM|¼|½)/) != nil { return false }
                if text.firstMatch(of: /^\s*[\d\s]+$/) != nil { return false }
                return text.rangeOfCharacter(from: .letters) != nil
            }
            .max(by: { $0.count < $1.count })

        return ExitInfo(number: number, destination: destination, milesAway: miles)
    }

    // MARK: Routes

    /// "WEST 10", "I-10", "US 60", "MEX 15D".
    static func parseRoute(_ text: String) -> RoadSign? {
        let direction = ["NORTH", "SOUTH", "EAST", "WEST",
                         "NORTE", "SUR", "ESTE", "OESTE"]
            .first { text.contains($0) }

        if let match = text.firstMatch(of: /\bI[-\s]?(\d{1,3})\b/) {
            return .route(shield: .interstate, number: String(match.1), direction: direction)
        }
        if let match = text.firstMatch(of: /\bINTERSTATE\s+(\d{1,3})\b/) {
            return .route(shield: .interstate, number: String(match.1), direction: direction)
        }
        if let match = text.firstMatch(of: /\bUS[-\s]?(\d{1,3})\b/) {
            return .route(shield: .usHighway, number: String(match.1), direction: direction)
        }
        if let match = text.firstMatch(of: /\bMEX[-\s]?(\d{1,3}D?)\b/) {
            return .route(shield: .mexicoFederal, number: String(match.1), direction: direction)
        }
        // A bare number beside a direction word is a state route shield, as
        // on the "347 SOUTH" panel.
        if let direction, let match = text.firstMatch(of: /\b(\d{1,3})\b/) {
            return .route(shield: .state, number: String(match.1), direction: direction)
        }
        return nil
    }

    // MARK: Services (the big blue panels)

    static func parseServices(_ text: String) -> [RoadSign] {
        var kinds: Set<ServiceKind> = []
        if text.firstMatch(of: /\b(GAS|FUEL|GASOLINA|DIESEL)\b/) != nil { kinds.insert(.gas) }
        if text.firstMatch(of: /\b(FOOD|COMIDA|RESTAURANTE)\b/) != nil { kinds.insert(.food) }
        if text.firstMatch(of: /\b(LODGING|HOTEL|MOTEL)\b/) != nil { kinds.insert(.lodging) }
        if text.firstMatch(of: /\b(CAMPING|RV\s+PARK)\b/) != nil { kinds.insert(.camping) }
        if text.firstMatch(of: /\bREST\s+AREA\b/) != nil { kinds.insert(.rest) }

        // Urban signage. Mexican city signs are largely pictograms, so only
        // the ones carrying a legend can be read this way — the rest need
        // the shape detector.
        if text.firstMatch(of: /\b(BUS\s+STOP|PARADA)\b/) != nil { kinds.insert(.busStop) }
        if text.firstMatch(of: /\b(TAXI|SITIO\s+DE\s+TAXIS)\b/) != nil { kinds.insert(.taxi) }
        if text.firstMatch(of: /\b(METRO|METROB[UÚ]S|SUBWAY)\b/) != nil { kinds.insert(.metro) }
        // "NO ESTACIONARSE" must be tested before plain "ESTACIONAMIENTO",
        // or a no-parking sign reads as an invitation to park.
        if text.firstMatch(of: /\b(NO\s+PARKING|NO\s+ESTACIONARSE|PROHIBIDO\s+ESTACIONARSE)\b/) != nil {
            kinds.insert(.noParking)
        } else if text.firstMatch(of: /\b(PARKING|ESTACIONAMIENTO)\b/) != nil {
            kinds.insert(.parking)
        }
        return kinds.isEmpty ? [] : [.services(kinds)]
    }

    // MARK: Landmarks (the brown panels)

    /// Brown signs point at parks, monuments, museums and historic sites.
    /// Matched by the words that appear on them, since colour alone can't be
    /// read from text.
    private static let landmarkWords = [
        "HERITAGE", "MUSEUM", "MONUMENT", "NATIONAL PARK", "STATE PARK",
        "HISTORIC", "MEMORIAL", "RECREATION", "SCENIC", "TRAILHEAD",
        "VISITOR CENTER", "WILDLIFE", "CANYON", "RUINS", "ZONA ARQUEOLOGICA",
    ]

    static func parseLandmark(_ lines: [String], joined: String) -> String? {
        guard landmarkWords.contains(where: { joined.contains($0) }) else { return nil }
        return lines
            .filter { line in
                let text = line.uppercased()
                return landmarkWords.contains { text.contains($0) }
            }
            .max(by: { $0.count < $1.count })
    }

    // MARK: Speed reduced

    static func parseSpeedReduced(_ text: String) -> Bool {
        text.firstMatch(of: /\bSPEED\s+(REDUCED|LIMIT)\s+AHEAD\b/) != nil
            || text.firstMatch(of: /\bREDUCED\s+SPEED\s+AHEAD\b/) != nil
            || text.firstMatch(of: /\bREDUZCA\s+SU\s+VELOCIDAD\b/) != nil
    }
}
