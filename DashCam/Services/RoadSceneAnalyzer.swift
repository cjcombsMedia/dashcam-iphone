import AudioToolbox
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// MARK: - Pure parsing & state machines (unit-tested)

/// Signs recognized from on-screen text.
enum RoadSign: Equatable {
    case speedLimit(Int)
    case speedHump(mph: Int?)
    case hospital
    case bikeLane
    case schoolCrossing(mph: Int?)
    case cityEntry(String)
    case fireStation(number: String?)
    case stop
    case yield
    case railroad
    case pedestrianCrossing
    case doNotEnter
    // Freeway signage.
    case bridgeClearance(Clearance)
    case exit(ExitInfo)
    case route(shield: RouteShield, number: String, direction: String?)
    case services(Set<ServiceKind>)
    case landmark(String)
    case speedReducedAhead
    case merge(MergeKind)

    /// The road-memory type this sign is remembered as, for the regulatory
    /// signs that map one-to-one. Nil for signs that carry a value.
    var featureType: RoadFeatureType? {
        switch self {
        case .stop: return .stop
        case .yield: return .yield
        case .railroad: return .railroad
        case .pedestrianCrossing: return .pedestrianCrossing
        case .doNotEnter: return .doNotEnter
        default: return nil
        }
    }
}

/// Parses OCR text lines into road signs. Pure logic.
enum RoadTextParser {
    static func parse(_ rawLines: [String]) -> [RoadSign] {
        // Billboards are the most common large text panel on a highway and
        // OCR reads them as eagerly as a road sign. Strip them first.
        let lines = BillboardFilter.roadworthy(rawLines)
        guard !lines.isEmpty else { return [] }
        let joined = lines.joined(separator: " ").uppercased()
        var signs: [RoadSign] = []

        // "SPEED LIMIT 45" (possibly split across lines).
        if let match = joined.firstMatch(of: /SPEED\s+LIMIT\s+(\d{1,2})/),
           let value = Int(match.1), (10...85).contains(value) {
            signs.append(.speedLimit(value))
        }

        // Mexico: "VELOCIDAD MAXIMA 80" is km/h, not mph. Posting 80 as a
        // US-style limit would be a 50 mph error.
        if let match = joined.firstMatch(of: /VELOCIDAD\s+M[AÁ]XIMA\s+(\d{1,3})/),
           let value = Int(match.1), (10...130).contains(value) {
            signs.append(.speedLimit(PostedSpeed(value: value, isMetric: true).mph))
        } else if let match = joined.firstMatch(of: /\b(\d{2,3})\s*KM\s*\/?\s*H\b/),
                  let value = Int(match.1), (10...130).contains(value) {
            signs.append(.speedLimit(PostedSpeed(value: value, isMetric: true).mph))
        }

        // Mexican regulatory legends.
        if joined.firstMatch(of: /\bALTO\b/) != nil { signs.append(.stop) }
        if joined.firstMatch(of: /\bCEDA\s+EL\s+PASO\b/) != nil { signs.append(.yield) }
        if joined.firstMatch(of: /\bTOPES?\b/) != nil { signs.append(.speedHump(mph: nil)) }
        if joined.firstMatch(of: /\bESCUELA\b/) != nil { signs.append(.schoolCrossing(mph: nil)) }
        if joined.firstMatch(of: /\bNO\s+HAY\s+PASO\b/) != nil { signs.append(.doNotEnter) }

        // Freeway guide, service, route and clearance panels.
        signs.append(contentsOf: HighwaySignParser.parse(lines))

        // "SPEED HUMP", "BUMP", optionally with "15 MPH".
        if joined.firstMatch(of: /\b(SPEED\s+)?(HUMP|BUMP)S?\b/) != nil {
            var humpSpeed: Int?
            if let speedMatch = joined.firstMatch(of: /(\d{1,2})\s*MPH/),
               let value = Int(speedMatch.1), (5...40).contains(value) {
                humpSpeed = value
            }
            signs.append(.speedHump(mph: humpSpeed))
        }

        // Regulatory legends. These are short, high-contrast words in a
        // standard typeface, so OCR reads them well — matched as whole words
        // to keep "STOPPED" or "YIELDING" on a truck's tailgate out.
        if joined.firstMatch(of: /\bSTOP\b/) != nil {
            signs.append(.stop)
        }
        if joined.firstMatch(of: /\bYIELD\b/) != nil {
            signs.append(.yield)
        }
        if joined.firstMatch(of: /\bDO\s+NOT\s+ENTER\b/) != nil
            || joined.firstMatch(of: /\bWRONG\s+WAY\b/) != nil {
            signs.append(.doNotEnter)
        }
        // Advance railroad warning is the "RXR"/"RR XING" legend; the
        // crossbuck itself carries "RAILROAD CROSSING".
        if joined.firstMatch(of: /\bRAIL\s?ROAD\b/) != nil
            || joined.firstMatch(of: /\bR\s?X\s?R\b/) != nil
            || joined.firstMatch(of: /\bRR\s+(XING|CROSSING)\b/) != nil {
            signs.append(.railroad)
        }
        if joined.firstMatch(of: /\bPED(ESTRIAN)?\s+(XING|CROSSING)\b/) != nil {
            signs.append(.pedestrianCrossing)
        }

        // "BIKE ROUTE" / "BIKE LANE".
        if joined.firstMatch(of: /BIKE\s+(ROUTE|LANE)/) != nil {
            signs.append(.bikeLane)
        }

        // Hospital: the word, or the classic standalone "H" panel. OCR often
        // attaches stray punctuation/arrows to the H, so strip non-letters.
        let hasStandaloneH = lines.contains { line in
            let letters = line.uppercased().filter { $0.isLetter }
            return letters == "H"
        }
        if joined.firstMatch(of: /\bHOSPITAL\b/) != nil || hasStandaloneH {
            signs.append(.hospital)
        }

        // School zone / crossing ("SCHOOL", "SCHOOL XING",
        // "15 MPH … SCHOOL IN SESSION" placards).
        if joined.firstMatch(of: /\bSCHOOL\b/) != nil {
            var schoolSpeed: Int?
            if let speedMatch = joined.firstMatch(of: /(\d{1,2})\s*MPH/),
               let value = Int(speedMatch.1), (10...25).contains(value) {
                schoolSpeed = value
            }
            signs.append(.schoolCrossing(mph: schoolSpeed))
        }

        // Fire station ahead — emergency vehicles may pull out.
        if let match = joined.firstMatch(of: /FIRE\s+STATION\s*#?\s*(\d{1,3})?/) {
            signs.append(.fireStation(number: match.1.map(String.init)))
        }

        // City/town entry: "WELCOME TUCSON … CITY LIMITS".
        if let match = joined.firstMatch(of: /WELCOME\s+(?:TO\s+)?([A-Z]{3,}(?:\s+[A-Z]{3,})?)/) {
            let name = String(match.1)
                .components(separatedBy: " ")
                .filter { !["CITY", "LIMITS", "TOWN", "THE"].contains($0) }
                .joined(separator: " ")
            if name.count >= 3 {
                signs.append(.cityEntry(name.capitalized))
            }
        }

        return signs
    }
}

/// What the signal mock on screen currently shows.
enum SignalDisplayKind: Equatable {
    case red
    case yellow
    case green
    case flashingYellow
}

/// Per-analysis observation of steady signal lamps in the upper frame.
struct SignalObservation: Equatable {
    var red = false
    var yellow = false
    var green = false
    var flashingYellow = false
}

/// Display rules per spec:
/// RED shows until GREEN appears; YELLOW shows until RED; GREEN hides after
/// 25 s; FLASHING YELLOW hides 3 s after last detection. Staleness windows
/// clear a display when its light hasn't been seen (drove past the light).
struct SignalStateMachine {
    static let greenCap: TimeInterval = 25
    static let redStale: TimeInterval = 15
    static let yellowStale: TimeInterval = 8
    static let flashingStale: TimeInterval = 3

    private(set) var display: SignalDisplayKind?
    private var shownAt: TimeInterval = 0
    private var lastSeen: [SignalDisplayKind: TimeInterval] = [:]
    /// After the 25 s green cap, don't re-show green until THIS light has
    /// actually left view for a few seconds.
    private var greenSuppressed = false

    mutating func process(now: TimeInterval, observation: SignalObservation) -> SignalDisplayKind? {
        if observation.red { lastSeen[.red] = now }
        if observation.yellow { lastSeen[.yellow] = now }
        if observation.green { lastSeen[.green] = now }
        if observation.flashingYellow { lastSeen[.flashingYellow] = now }

        switch display {
        case .red:
            if observation.green {
                set(.green, now)
            } else if now - (lastSeen[.red] ?? 0) > Self.redStale {
                display = nil
            }
        case .yellow:
            if observation.red {
                set(.red, now)
            } else if now - (lastSeen[.yellow] ?? 0) > Self.yellowStale {
                display = nil
            }
        case .green:
            if observation.red {
                set(.red, now)
            } else if observation.yellow {
                set(.yellow, now)
            } else if now - shownAt > Self.greenCap {
                display = nil
                greenSuppressed = true
            }
        case .flashingYellow:
            if observation.red {
                set(.red, now)
            } else if now - (lastSeen[.flashingYellow] ?? 0) > Self.flashingStale {
                display = nil
            }
        case nil:
            break
        }

        if greenSuppressed, now - (lastSeen[.green] ?? 0) > 4 {
            greenSuppressed = false
        }

        if display == nil {
            if observation.red {
                set(.red, now)
            } else if observation.yellow {
                set(.yellow, now)
            } else if observation.flashingYellow {
                set(.flashingYellow, now)
            } else if observation.green, !greenSuppressed {
                set(.green, now)
            }
        }
        return display
    }

    private mutating func set(_ kind: SignalDisplayKind, _ now: TimeInterval) {
        display = kind
        shownAt = now
        lastSeen[kind] = now
    }
}

// MARK: - On-screen scene state (main actor)

struct CyclistWarning: Equatable {
    enum Direction { case left, right }
    var direction: Direction
    var until: Date
}

/// The live road-scene state driving the on-screen mock signs.
@MainActor
final class RoadScene: ObservableObject {
    /// The analyzer feeding this scene (kept here so views/settings can
    /// toggle it without a separate injection path).
    var analyzer: RoadSceneAnalyzer?
    /// Geo memory: learns confirmed detections and supplies signs from
    /// memory on later passes.
    var memory: RoadMemory?
    /// Supplies the current fix (lat, lon, heading) for learning/recall.
    var positionProvider: (() -> (lat: Double, lon: Double, heading: Double)?)?
    /// Which signs on screen are currently coming from memory (M badge).
    @Published private(set) var memorySourcedTypes: Set<RoadFeatureType> = []

    static let hospitalDuration: TimeInterval = 45
    static let humpDuration: TimeInterval = 12
    static let bikeDuration: TimeInterval = 30
    static let schoolDuration: TimeInterval = 25
    static let fireStationDuration: TimeInterval = 20
    /// How long a stop / yield / crossing sign stays on the glass. Long
    /// enough to act on, short enough that it's gone by the next junction.
    static let regulatoryDuration: TimeInterval = 14
    /// Guide panels repeat every mile or so; hold one until the next.
    static let guideDuration: TimeInterval = 30
    /// A clearance warning matters right up to the underpass.
    static let clearanceDuration: TimeInterval = 25
    static let cyclistLinger: TimeInterval = 3
    static let cyclistSoundCooldown: TimeInterval = 8

    /// Latest speed limit; persists until a NEW speed sign is read.
    @Published private(set) var speedLimit: Int?
    @Published private(set) var humpUntil: Date?
    @Published private(set) var humpSpeed: Int?
    @Published private(set) var hospitalUntil: Date?
    @Published private(set) var bikeUntil: Date?
    @Published private(set) var schoolUntil: Date?
    @Published private(set) var schoolSpeed: Int?
    @Published private(set) var cityUntil: Date?
    @Published private(set) var cityName: String?
    @Published private(set) var fireStationUntil: Date?
    @Published private(set) var fireStationLabel: String?
    @Published private(set) var signal: SignalDisplayKind?
    /// Regulatory and warning signs (stop, yield, railroad, crossing, do not
    /// enter), each held until its own expiry. One dictionary rather than a
    /// pair of properties per sign — they all behave identically.
    @Published private(set) var regulatorySigns: [RoadFeatureType: Date] = [:]
    /// Freeway signage — these carry data rather than a bare type, so each
    /// keeps its own value alongside its expiry.
    @Published private(set) var exitAhead: ExitInfo?
    @Published private(set) var routeShield: (shield: RouteShield, number: String, direction: String?)?
    @Published private(set) var clearance: Clearance?
    @Published private(set) var services: Set<ServiceKind> = []
    @Published private(set) var landmarkName: String?
    @Published private(set) var mergeKind: MergeKind?
    @Published private(set) var speedReducedAhead = false
    private var highwayExpiry: [String: Date] = [:]
    @Published private(set) var pedestrianBoxes: [CGRect] = []
    @Published private(set) var cyclist: CyclistWarning?

    private var machine = SignalStateMachine()
    private var lastCyclistSound = Date.distantPast
    private var pedestrianLastSeen = Date.distantPast
    /// After a hump window expires, wait before a new sign can re-trigger —
    /// hump zones repeat their signs every few hundred feet.
    private var humpCooldownUntil = Date.distantPast
    private var schoolCooldownUntil = Date.distantPast
    /// The same "Welcome" sign OCRs for several seconds; announce a city
    /// once, and again only for a different name or after a long gap.
    private var lastCityAnnounced: String?
    private var cityCooldownUntil = Date.distantPast
    private var fireStationCooldownUntil = Date.distantPast
    private var tick: Timer?

    init() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// High-rate signal updates (~15 Hz lamp scans); published only when the
    /// display actually changes.
    func applySignal(_ observation: SignalObservation) {
        let next = machine.process(now: Date().timeIntervalSinceReferenceDate, observation: observation)
        if next != signal {
            signal = next
            if let next {
                DiagLog.shared.info("Road: signal \(next)")
            }
        }
    }

    func apply(
        signs: [RoadSign],
        pedestrians: [CGRect],
        cyclistSide: CyclistWarning.Direction?
    ) {
        let now = Date()
        // Teach memory what the camera just confirmed, so this sign appears
        // on later passes even if the camera misses it.
        if let memory, let fix = positionProvider?() {
            for sign in signs {
                switch sign {
                case .speedLimit(let value):
                    memory.learn(type: .speedLimit, value: String(value),
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .speedHump(let mph):
                    memory.learn(type: .hump, value: mph.map(String.init),
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .schoolCrossing(let mph):
                    memory.learn(type: .school, value: mph.map(String.init),
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .hospital:
                    memory.learn(type: .hospital, value: nil,
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .bikeLane:
                    memory.learn(type: .bike, value: nil,
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .cityEntry(let name):
                    memory.learn(type: .city, value: name,
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .fireStation(let number):
                    memory.learn(type: .fireStation, value: number,
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .stop, .yield, .railroad, .pedestrianCrossing, .doNotEnter:
                    if let type = sign.featureType {
                        memory.learn(type: type, value: nil,
                                     latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                    }
                case .bridgeClearance(let value):
                    // Worth pinning: an underpass never moves, and a truck
                    // needs the warning even when the sign is unreadable.
                    memory.learn(type: .lowClearance, value: String(value.totalInches),
                                 latitude: fix.lat, longitude: fix.lon, heading: fix.heading)
                case .exit, .route, .services, .landmark, .speedReducedAhead, .merge:
                    // Guide and lane signage is read fresh each pass. Pinning
                    // an exit panel would just replay "2 MILES" at the exit.
                    break
                }
            }
        }

        for sign in signs {
            switch sign {
            case .speedLimit(let value):
                if speedLimit != value {
                    speedLimit = value
                    DiagLog.shared.info("Road: speed limit \(value)")
                }
            case .speedHump(let mph):
                if humpUntil != nil {
                    // Window already running: update the speed plate if we
                    // just read one, but never extend the window.
                    humpSpeed = mph ?? humpSpeed
                } else if now > humpCooldownUntil {
                    humpUntil = now.addingTimeInterval(Self.humpDuration)
                    humpSpeed = mph
                    AlertSounds.shared.play(.hump)
                    DiagLog.shared.info("Road: speed hump\(mph.map { " \($0) mph" } ?? "")")
                }
            case .hospital:
                if hospitalUntil == nil {
                    AlertSounds.shared.play(.hospital)
                    DiagLog.shared.info("Road: hospital sign")
                }
                hospitalUntil = now.addingTimeInterval(Self.hospitalDuration)
            case .bikeLane:
                bikeUntil = now.addingTimeInterval(Self.bikeDuration)
            case .schoolCrossing(let mph):
                if schoolUntil != nil {
                    schoolSpeed = mph ?? schoolSpeed
                } else if now > schoolCooldownUntil {
                    schoolUntil = now.addingTimeInterval(Self.schoolDuration)
                    schoolSpeed = mph
                    AlertSounds.shared.play(.school)
                    DiagLog.shared.info("Road: school crossing\(mph.map { " \($0) mph" } ?? "")")
                }
            case .fireStation(let number):
                if fireStationUntil == nil, now > fireStationCooldownUntil {
                    fireStationLabel = number.map { "FIRE STATION \($0)" } ?? "FIRE STATION"
                    fireStationUntil = now.addingTimeInterval(Self.fireStationDuration)
                    AlertSounds.shared.play(.fireStation)
                    DiagLog.shared.info("Road: \(fireStationLabel ?? "fire station")")
                }
            case .cityEntry(let name):
                if name != lastCityAnnounced || now > cityCooldownUntil {
                    lastCityAnnounced = name
                    cityCooldownUntil = now.addingTimeInterval(600)
                    cityName = name
                    cityUntil = now.addingTimeInterval(15)
                    AlertSounds.shared.play(.city)
                    DiagLog.shared.info("Road: entering \(name)")
                }
            case .bridgeClearance(let value):
                clearance = value
                highwayExpiry["clearance"] = now.addingTimeInterval(Self.clearanceDuration)
                DiagLog.shared.info("Road: clearance \(value.label)")
            case .exit(let info):
                exitAhead = info
                highwayExpiry["exit"] = now.addingTimeInterval(Self.guideDuration)
            case .route(let shield, let number, let direction):
                routeShield = (shield, number, direction)
                highwayExpiry["route"] = now.addingTimeInterval(Self.guideDuration)
            case .services(let kinds):
                services = kinds
                highwayExpiry["services"] = now.addingTimeInterval(Self.guideDuration)
            case .landmark(let name):
                landmarkName = name
                highwayExpiry["landmark"] = now.addingTimeInterval(Self.guideDuration)
            case .speedReducedAhead:
                if !speedReducedAhead { AlertSounds.shared.play(.hump) }
                speedReducedAhead = true
                highwayExpiry["speedReduced"] = now.addingTimeInterval(Self.regulatoryDuration)
            case .merge(let kind):
                mergeKind = kind
                highwayExpiry["merge"] = now.addingTimeInterval(Self.regulatoryDuration)
            case .stop, .yield, .railroad, .pedestrianCrossing, .doNotEnter:
                if let type = sign.featureType, regulatorySigns[type] == nil {
                    regulatorySigns[type] = now.addingTimeInterval(Self.regulatoryDuration)
                    AlertSounds.shared.play(type == .pedestrianCrossing ? .school : .hump)
                    DiagLog.shared.info("Road: \(type.label)")
                }
            }
        }

        if !pedestrians.isEmpty {
            pedestrianBoxes = Array(pedestrians.prefix(5))
            pedestrianLastSeen = now
        }

        if let side = cyclistSide {
            let isNewEvent = cyclist == nil
            cyclist = CyclistWarning(direction: side, until: now.addingTimeInterval(Self.cyclistLinger))
            if isNewEvent, now.timeIntervalSince(lastCyclistSound) > Self.cyclistSoundCooldown {
                lastCyclistSound = now
                AlertSounds.shared.play(.cyclist)
                Haptics.warning()
                DiagLog.shared.info("Road: cyclist warning (\(side == .right ? "right" : "left"))")
            }
        }
    }

    /// Applies remembered features for the current position — signs appear
    /// from memory when the camera hasn't just detected them.
    private func applyMemory() {
        guard let memory, let fix = positionProvider?() else {
            if !memorySourcedTypes.isEmpty { memorySourcedTypes = [] }
            return
        }
        let entered = memory.updatePosition(
            latitude: fix.lat, longitude: fix.lon, heading: fix.heading
        )
        let now = Date()
        var sourced: Set<RoadFeatureType> = []

        for feature in memory.active {
            switch feature.type {
            case .speedLimit:
                if let value = feature.numericValue, speedLimit != value {
                    speedLimit = value
                    sourced.insert(.speedLimit)
                } else if speedLimit == feature.numericValue {
                    sourced.insert(.speedLimit)
                }
            case .hump:
                if humpUntil == nil {
                    humpUntil = now.addingTimeInterval(Self.humpDuration)
                    humpSpeed = feature.numericValue
                }
                sourced.insert(.hump)
            case .school:
                if schoolUntil == nil {
                    schoolUntil = now.addingTimeInterval(Self.schoolDuration)
                    schoolSpeed = feature.numericValue
                }
                sourced.insert(.school)
            case .hospital:
                if hospitalUntil == nil {
                    hospitalUntil = now.addingTimeInterval(Self.hospitalDuration)
                }
                sourced.insert(.hospital)
            case .bike:
                if bikeUntil == nil {
                    bikeUntil = now.addingTimeInterval(Self.bikeDuration)
                }
                sourced.insert(.bike)
            case .city:
                if cityUntil == nil {
                    cityName = feature.value
                    cityUntil = now.addingTimeInterval(15)
                }
                sourced.insert(.city)
            case .fireStation:
                if fireStationUntil == nil {
                    fireStationLabel = feature.value.map { "FIRE STATION \($0)" } ?? "FIRE STATION"
                    fireStationUntil = now.addingTimeInterval(Self.fireStationDuration)
                }
                sourced.insert(.fireStation)
            case .stop, .yield, .railroad, .pedestrianCrossing, .doNotEnter:
                if regulatorySigns[feature.type] == nil {
                    regulatorySigns[feature.type] = now.addingTimeInterval(Self.regulatoryDuration)
                }
                sourced.insert(feature.type)
            case .lowClearance:
                if clearance == nil, let inches = feature.numericValue {
                    clearance = Clearance(feet: inches / 12, inches: inches % 12)
                    highwayExpiry["clearance"] = now.addingTimeInterval(Self.clearanceDuration)
                }
                sourced.insert(.lowClearance)
            }
        }

        // Chime once when newly entering a remembered feature's range.
        for feature in entered {
            switch feature.type {
            case .school: AlertSounds.shared.play(.school)
            case .hump: AlertSounds.shared.play(.hump)
            case .hospital: AlertSounds.shared.play(.hospital)
            case .city: AlertSounds.shared.play(.city)
            case .fireStation: AlertSounds.shared.play(.fireStation)
            case .stop, .yield, .railroad, .doNotEnter, .lowClearance:
                AlertSounds.shared.play(.hump)   // the same "pay attention" tone
            case .pedestrianCrossing:
                AlertSounds.shared.play(.school)
            case .speedLimit, .bike: break
            }
            DiagLog.shared.info("Memory: recalled \(feature.type.rawValue)\(feature.value.map { " \($0)" } ?? "")")
        }

        if memorySourcedTypes != sourced {
            memorySourcedTypes = sourced
        }
    }

    private func prune() {
        applyMemory()
        let now = Date()
        if let until = humpUntil, until < now {
            humpUntil = nil
            humpCooldownUntil = now.addingTimeInterval(10)
        }
        if let until = hospitalUntil, until < now { hospitalUntil = nil }
        if let until = bikeUntil, until < now { bikeUntil = nil }
        let expiredSigns = regulatorySigns.filter { $0.value < now }.keys
        for type in expiredSigns { regulatorySigns.removeValue(forKey: type) }

        for (key, until) in highwayExpiry where until < now {
            highwayExpiry.removeValue(forKey: key)
            switch key {
            case "clearance": clearance = nil
            case "exit": exitAhead = nil
            case "route": routeShield = nil
            case "services": services = []
            case "landmark": landmarkName = nil
            case "speedReduced": speedReducedAhead = false
            case "merge": mergeKind = nil
            default: break
            }
        }
        if let until = schoolUntil, until < now {
            schoolUntil = nil
            schoolCooldownUntil = now.addingTimeInterval(10)
        }
        if let until = cityUntil, until < now {
            cityUntil = nil
        }
        if let until = fireStationUntil, until < now {
            fireStationUntil = nil
            fireStationLabel = nil
            fireStationCooldownUntil = now.addingTimeInterval(20)
        }
        if let warning = cyclist, warning.until < now { cyclist = nil }
        if !pedestrianBoxes.isEmpty, now.timeIntervalSince(pedestrianLastSeen) > 1.0 {
            pedestrianBoxes = []
        }
        // Keep the signal machine ticking so stale displays clear.
        let next = machine.process(now: now.timeIntervalSinceReferenceDate, observation: SignalObservation())
        if next != signal { signal = next }
    }
}

/// Crops a camera buffer to a normalized region and renders it into a new
/// buffer — a digital telephoto so Vision sees distant people and signs at
/// usable size instead of a few pixels in a wide frame.
final class CropRenderer {
    static let shared = CropRenderer()

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()

    /// `region` is in top-left normalized coordinates.
    func crop(_ buffer: CVPixelBuffer, to region: CGRect) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixelRect = CGRect(
            x: region.minX * Double(width),
            // CoreImage is bottom-left origin.
            y: (1 - region.maxY) * Double(height),
            width: region.width * Double(width),
            height: region.height * Double(height)
        ).integral
        guard pixelRect.width >= 32, pixelRect.height >= 32 else { return nil }

        let image = CIImage(cvPixelBuffer: buffer)
            .cropped(to: pixelRect)
            .transformed(by: CGAffineTransform(translationX: -pixelRect.minX, y: -pixelRect.minY))

        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(pixelRect.width), Int(pixelRect.height),
            CVPixelBufferGetPixelFormatType(buffer),
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let result = output else { return nil }

        context.render(image, to: result)
        return result
    }
}

// MARK: - Frame analyzer (Vision + color blobs)

/// Analyzes camera frames (~4 fps) for text signs, humans, and steady signal
/// lamps. Fully on-device; results land in `RoadScene` on the main actor.
final class RoadSceneAnalyzer {
    let scene: RoadScene

    private let queue = DispatchQueue(label: "com.cjcombs.dashcam.roadscene", qos: .utility)
    /// Fast lane for the signal-lamp scan (~15 Hz, sub-millisecond work).
    private let lampQueue = DispatchQueue(label: "com.cjcombs.dashcam.roadlamps", qos: .userInitiated)
    private var busy = false
    private var lampBusy = false
    private let busyLock = NSLock()
    private var enabledFlag = true
    private var lastDispatchedObservation: SignalObservation?

    /// Rolling amber presence for flashing-yellow detection (~2 s window).
    private var amberHistory: [(time: Double, present: Bool)] = []
    /// Consecutive-scan confirmation per steady color: a lamp must persist
    /// across 3 scans (~0.2 s) before the state machine sees it, which kills
    /// momentary scene flashes while driving.
    private var redStreak = 0
    private var yellowStreak = 0
    private var greenStreak = 0
    /// Text bounding boxes from the last OCR pass — signs have text, signal
    /// heads don't, so lamp candidates inside text regions are discarded.
    private var textRegions: [CGRect] = []
    /// Consecutive-frame confirmation for humans at the road edges.
    private var edgeStreak: [CyclistWarning.Direction: Int] = [:]
    /// Confirmation streaks for text-free pictogram signs.
    private var schoolBlobStreak = 0
    private var hospitalBlobStreak = 0
    private var bikeBlobStreak = 0
    /// Which zoom crop this pass analyzes (round-robin).
    private var cropIndex = 0
    /// Signal lamp regions (normalized, top-left origin) — consumed by the
    /// emergency detector as exclusion zones.
    private let exclusionLock = NSLock()
    private var signalRegions: [CGRect] = []

    init(scene: RoadScene) {
        self.scene = scene
    }

    var isEnabled: Bool {
        get { busyLock.lock(); defer { busyLock.unlock() }; return enabledFlag }
        set { busyLock.lock(); enabledFlag = newValue; busyLock.unlock() }
    }

    /// Current signal-lamp regions for the emergency detector.
    func currentSignalRegions() -> [CGRect] {
        exclusionLock.lock()
        defer { exclusionLock.unlock() }
        return signalRegions
    }

    // MARK: - Training Mode hooks (same logic, callable on still images)

    static var diagnosticCropRegions: [CGRect] { cropRegions }
    static var diagnosticHumanCropRegions: [CGRect] { humanCropRegions }

    static func diagnosticScanLamps(
        _ pixelBuffer: CVPixelBuffer
    ) -> (red: Bool, yellow: Bool, green: Bool, regions: [CGRect]) {
        scanSignalLamps(pixelBuffer)
    }

    static func diagnosticSchoolBlob(_ pixelBuffer: CVPixelBuffer) -> Bool {
        scanSchoolSignBlob(pixelBuffer)
    }

    static func diagnosticPictograms(_ pixelBuffer: CVPixelBuffer) -> PictogramHits {
        scanPictogramSigns(pixelBuffer)
    }

    /// Fast lane: signal-lamp color scan, called every 2nd frame (~15 Hz)
    /// so traffic lights are checked constantly — even at 75 mph a light
    /// gets dozens of looks. Drops frames if the previous scan is running.
    func ingestLamp(_ pixelBuffer: CVPixelBuffer, at time: Double) {
        busyLock.lock()
        let canRun = enabledFlag && !lampBusy
        if canRun { lampBusy = true }
        busyLock.unlock()
        guard canRun else { return }

        lampQueue.async {
            defer {
                self.busyLock.lock()
                self.lampBusy = false
                self.busyLock.unlock()
            }
            self.scanLamps(pixelBuffer, at: time)
        }
    }

    private func scanLamps(_ pixelBuffer: CVPixelBuffer, at time: Double) {
        exclusionLock.lock()
        let exclusions = textRegions
        exclusionLock.unlock()

        let lamps = Self.scanSignalLamps(pixelBuffer, excluding: exclusions)
        exclusionLock.lock()
        signalRegions = lamps.regions
        exclusionLock.unlock()

        // Flashing detection needs the RAW on/off pattern.
        amberHistory.append((time, lamps.yellow))
        amberHistory.removeAll { $0.time < time - 2.2 }
        var amberFlips = 0
        for (a, b) in zip(amberHistory, amberHistory.dropFirst()) where a.present != b.present {
            amberFlips += 1
        }
        let flashingYellow = amberFlips >= 3

        // Steady colors need 2 consecutive confirmations. (Display is
        // speed-gated now, so tuning favors sensitivity.)
        redStreak = lamps.red ? redStreak + 1 : 0
        yellowStreak = lamps.yellow ? yellowStreak + 1 : 0
        greenStreak = lamps.green ? greenStreak + 1 : 0

        var observation = SignalObservation(
            red: redStreak >= 2,
            yellow: yellowStreak >= 2 && !flashingYellow,
            green: greenStreak >= 2,
            flashingYellow: flashingYellow
        )
        if flashingYellow { observation.yellow = false }

        // Publish only when something changed; the scene's own tick handles
        // staleness between changes.
        guard observation != lastDispatchedObservation else { return }
        lastDispatchedObservation = observation
        let sceneRef = scene
        DispatchQueue.main.async {
            sceneRef.applySignal(observation)
        }
    }

    /// Heavy lane: Vision OCR + human detection (~5 Hz). Called on the
    /// capture output queue; drops the frame if the previous analysis is
    /// still running.
    func ingest(_ pixelBuffer: CVPixelBuffer, at time: Double) {
        busyLock.lock()
        let canRun = enabledFlag && !busy
        if canRun { busy = true }
        busyLock.unlock()
        guard canRun else { return }

        queue.async {
            defer {
                self.busyLock.lock()
                self.busy = false
                self.busyLock.unlock()
            }
            self.analyze(pixelBuffer, at: time)
        }
    }

    /// Digital-telephoto regions of interest (Vision coords, bottom-left
    /// origin). Signs are small in a wide frame; analyzing crops at native
    /// resolution is what makes distant text readable. Rotated one per pass
    /// so the cost stays bounded.
    private static let cropRegions: [CGRect] = [
        CGRect(x: 0.30, y: 0.28, width: 0.40, height: 0.50), // center — signals, overhead signs
        CGRect(x: 0.55, y: 0.20, width: 0.45, height: 0.55), // right shoulder — most road signs
        CGRect(x: 0.05, y: 0.20, width: 0.40, height: 0.55), // left shoulder
    ]

    /// Crops for human detection, in TOP-LEFT coordinates. People appear in
    /// the road band — the middle of the frame vertically — so these zoom
    /// there rather than at the sky or the hood.
    private static let humanCropRegions: [CGRect] = [
        CGRect(x: 0.30, y: 0.35, width: 0.45, height: 0.45), // ahead / right shoulder
        CGRect(x: 0.55, y: 0.35, width: 0.45, height: 0.45), // right shoulder close
        CGRect(x: 0.05, y: 0.35, width: 0.45, height: 0.45), // left shoulder
    ]

    private func analyze(_ pixelBuffer: CVPixelBuffer, at time: Double) {
        // Vision: text (full frame + a rotating zoom crop) + humans.
        let fullText = VNRecognizeTextRequest()
        fullText.recognitionLevel = .accurate
        fullText.usesLanguageCorrection = false
        fullText.minimumTextHeight = 0.012

        cropIndex = (cropIndex + 1) % Self.cropRegions.count
        let cropText = VNRecognizeTextRequest()
        cropText.recognitionLevel = .accurate
        cropText.usesLanguageCorrection = false
        cropText.minimumTextHeight = 0.02
        cropText.regionOfInterest = Self.cropRegions[cropIndex]

        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([fullText, cropText, humanRequest])

        // People far down the road are only a few percent of a wide frame —
        // too small for reliable detection. Re-run human detection on an
        // actual cropped buffer (digital telephoto) and merge the results.
        var croppedHumans: [CGRect] = []
        let humanCrop = Self.humanCropRegions[cropIndex % Self.humanCropRegions.count]
        if let cropBuffer = CropRenderer.shared.crop(pixelBuffer, to: humanCrop) {
            let cropRequest = VNDetectHumanRectanglesRequest()
            cropRequest.upperBodyOnly = false
            let cropHandler = VNImageRequestHandler(cvPixelBuffer: cropBuffer, orientation: .up)
            try? cropHandler.perform([cropRequest])
            croppedHumans = (cropRequest.results ?? []).map { result in
                // Map the crop-relative box back into full-frame coordinates
                // (Vision boxes are bottom-left origin).
                let bb = result.boundingBox
                return CGRect(
                    x: humanCrop.minX + bb.minX * humanCrop.width,
                    y: humanCrop.minY + (1 - bb.maxY) * humanCrop.height,
                    width: bb.width * humanCrop.width,
                    height: bb.height * humanCrop.height
                )
            }
        }

        let textRequest = fullText
        let lines: [String] = ((fullText.results ?? []) + (cropText.results ?? [])).compactMap {
            $0.topCandidates(1).first?.string
        }
        var signs = RoadTextParser.parse(lines)

        // Symbol signs (school pictogram, hospital H, bike route) carry no
        // readable text — they're found by sign color + shape, confirmed
        // across two passes.
        let pictograms = Self.scanPictogramSigns(pixelBuffer)
        schoolBlobStreak = pictograms.school ? schoolBlobStreak + 1 : 0
        hospitalBlobStreak = pictograms.hospital ? hospitalBlobStreak + 1 : 0
        bikeBlobStreak = pictograms.bike ? bikeBlobStreak + 1 : 0

        if schoolBlobStreak >= 2,
           !signs.contains(where: { if case .schoolCrossing = $0 { return true } else { return false } }) {
            signs.append(.schoolCrossing(mph: nil))
        }
        if hospitalBlobStreak >= 2, !signs.contains(.hospital) {
            signs.append(.hospital)
        }
        if bikeBlobStreak >= 2, !signs.contains(.bikeLane) {
            signs.append(.bikeLane)
        }

        // Text regions mark sign faces — excluded from the lamp scan, but
        // UNPADDED: street-name signs share the mast arm with signal heads,
        // and padding was swallowing the lamps beside them.
        let regions: [CGRect] = (textRequest.results ?? []).map { result in
            let bb = result.boundingBox
            return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        }
        exclusionLock.lock()
        textRegions = regions
        exclusionLock.unlock()

        // Humans: Vision rects are bottom-left origin; convert to top-left.
        // EVERY person gets a box (cyclists, walkers, runners) — the old
        // centre/edge split silently dropped riders that weren't far enough
        // to the side, like a cyclist on a curving shoulder at x≈0.6.
        var people: [CGRect] = (humanRequest.results ?? []).map { result in
            let bb = result.boundingBox
            return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        }
        people.append(contentsOf: croppedHumans)

        // Merge near-duplicates from the full frame and the crop.
        var merged: [CGRect] = []
        for person in people where person.height >= 0.035 {
            if merged.contains(where: { $0.intersects(person.insetBy(dx: -0.01, dy: -0.01)) }) { continue }
            merged.append(person)
        }
        let pedestrians = merged

        // Warn about the most prominent person, arrow pointing to their side.
        var side: CyclistWarning.Direction?
        if let nearest = merged.max(by: { $0.height < $1.height }) {
            side = nearest.midX >= 0.5 ? .right : .left
        }

        // Require two consecutive sightings before warning (debounce).
        var confirmedSide: CyclistWarning.Direction?
        if let side {
            edgeStreak[side, default: 0] += 1
            edgeStreak[side == .right ? .left : .right] = 0
            if edgeStreak[side, default: 0] >= 2 {
                confirmedSide = side
            }
        } else {
            edgeStreak = [:]
        }

        let sceneRef = scene
        DispatchQueue.main.async {
            sceneRef.apply(
                signs: signs,
                pedestrians: pedestrians,
                cyclistSide: confirmedSide
            )
        }
    }

    /// Symbol signs carry little or no text — a lone "H", a bicycle glyph —
    /// which OCR cannot read at any resolution, so they're found by their
    /// distinctive sign colors and shape instead.
    struct PictogramHits {
        var school = false
        var hospital = false
        var bike = false
    }

    static func scanPictogramSigns(_ pixelBuffer: CVPixelBuffer) -> PictogramHits {
        var hits = PictogramHits()
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return hits }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return hits }

        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard chromaWidth > 0, chromaHeight > 0 else { return hits }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // Dense grid — roadside symbol signs are only ~2% of frame width.
        let stepX = max(1, chromaWidth / 160)
        let stepY = max(1, chromaHeight / 90)
        let maxY = Int(Double(chromaHeight) * 0.75)

        struct Stat {
            var count = 0
            var minGX = Int.max, maxGX = -1, minGY = Int.max, maxGY = -1
            mutating func add(_ gx: Int, _ gy: Int) {
                count += 1
                minGX = min(minGX, gx); maxGX = max(maxGX, gx)
                minGY = min(minGY, gy); maxGY = max(maxGY, gy)
            }
        }
        var school = Stat(), hospital = Stat(), bike = Stat()

        var gy = 0
        var y = 0
        while y < maxY {
            var gx = 0
            var x = 0
            while x < chromaWidth {
                let cb = Int(chroma[y * chromaRowBytes + 2 * x])
                let cr = Int(chroma[y * chromaRowBytes + 2 * x + 1])
                let brightness = Int(luma[(2 * y) * lumaRowBytes + 2 * x])

                // Fluorescent yellow-green (school pictogram).
                if cb <= 95, cr >= 105, cr <= 135, brightness >= 140 {
                    school.add(gx, gy)
                }
                // Highway-services blue (hospital H): deeply saturated blue
                // and DARK — bright blue sky fails the brightness ceiling.
                if cb >= 160, cr <= 125, brightness >= 35, brightness <= 130 {
                    hospital.add(gx, gy)
                }
                // Sign green (bike route): Cr well below neutral with a
                // near-neutral Cb — foliage sits much closer to neutral Cr.
                if cr <= 100, cb >= 108, cb <= 142, brightness >= 45, brightness <= 140 {
                    bike.add(gx, gy)
                }
                x += stepX
                gx += 1
            }
            y += stepY
            gy += 1
        }

        /// Sign-shaped: small-to-medium, compact, and dense.
        func isSign(_ stat: Stat, minWidth: Double, maxWidth: Double, maxHeight: Double, minCount: Int) -> Bool {
            guard stat.count >= minCount, stat.maxGX >= stat.minGX else { return false }
            let cellsW = stat.maxGX - stat.minGX + 1
            let cellsH = stat.maxGY - stat.minGY + 1
            let widthN = Double(cellsW * stepX) / Double(chromaWidth)
            let heightN = Double(cellsH * stepY) / Double(chromaHeight)
            guard widthN >= minWidth, widthN <= maxWidth, heightN <= maxHeight else { return false }
            let density = Double(stat.count) / Double(cellsW * cellsH)
            return density >= 0.30
        }

        /// Symbol signs have a bright white glyph inside the colored panel —
        /// the "H", the bicycle. Blue vehicles and green foliage don't.
        func hasWhiteGlyph(_ stat: Stat) -> Bool {
            guard stat.maxGX >= stat.minGX else { return false }
            var white = 0
            var gyy = stat.minGY
            while gyy <= stat.maxGY {
                var gxx = stat.minGX
                while gxx <= stat.maxGX {
                    let px = gxx * stepX
                    let py = gyy * stepY
                    guard px < chromaWidth, py < chromaHeight else { gxx += 1; continue }
                    let cb = Int(chroma[py * chromaRowBytes + 2 * px])
                    let cr = Int(chroma[py * chromaRowBytes + 2 * px + 1])
                    let brightness = Int(luma[(2 * py) * lumaRowBytes + 2 * px])
                    if brightness >= 150, abs(cb - 128) <= 28, abs(cr - 128) <= 28 {
                        white += 1
                    }
                    gxx += 1
                }
                gyy += 1
            }
            return white >= 1
        }

        hits.school = isSign(school, minWidth: 0.012, maxWidth: 0.18, maxHeight: 0.22, minCount: 6)
        hits.hospital = isSign(hospital, minWidth: 0.006, maxWidth: 0.10, maxHeight: 0.14, minCount: 4)
            && hasWhiteGlyph(hospital)
        hits.bike = isSign(bike, minWidth: 0.006, maxWidth: 0.12, maxHeight: 0.16, minCount: 4)
            && hasWhiteGlyph(bike)
        return hits
    }

    /// Detects the fluorescent yellow-green of school-crossing pictogram
    /// signs: a compact medium-size lime blob (distinctly cooler than the
    /// warm yellow of hump/warning signs, far more saturated than foliage).
    private static func scanSchoolSignBlob(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return false }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }

        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard chromaWidth > 0, chromaHeight > 0 else { return false }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        let stepX = max(1, chromaWidth / 128)
        let stepY = max(1, chromaHeight / 72)
        let maxY = Int(Double(chromaHeight) * 0.70)

        var count = 0
        var minGX = Int.max, maxGX = -1, minGY = Int.max, maxGY = -1

        var gy = 0
        var y = 0
        while y < maxY {
            var gx = 0
            var x = 0
            while x < chromaWidth {
                let cb = Int(chroma[y * chromaRowBytes + 2 * x])
                let cr = Int(chroma[y * chromaRowBytes + 2 * x + 1])
                let brightness = Int(luma[(2 * y) * lumaRowBytes + 2 * x])

                // Fluorescent yellow-green: very low blue, near-neutral red,
                // very bright. Foliage is darker and less saturated; warm
                // sign-yellow has higher Cr.
                if cb <= 95, cr >= 105, cr <= 135, brightness >= 140 {
                    count += 1
                    minGX = min(minGX, gx); maxGX = max(maxGX, gx)
                    minGY = min(minGY, gy); maxGY = max(maxGY, gy)
                }
                x += stepX
                gx += 1
            }
            y += stepY
            gy += 1
        }

        guard count >= 8, count <= 500, maxGX >= minGX else { return false }
        let cellsW = maxGX - minGX + 1
        let cellsH = maxGY - minGY + 1
        let widthN = Double(cellsW * stepX) / Double(chromaWidth)
        let heightN = Double(cellsH * stepY) / Double(chromaHeight)
        guard widthN >= 0.015, widthN <= 0.18, heightN >= 0.015, heightN <= 0.22 else { return false }
        let density = Double(count) / Double(cellsW * cellsH)
        return density >= 0.25
    }

    /// Samples the top 60% of the frame's chroma plane for small clusters of
    /// saturated red / amber / green — traffic signal lamps. Returns which
    /// colors are present plus their regions for emergency-light exclusion.
    private static func scanSignalLamps(
        _ pixelBuffer: CVPixelBuffer,
        excluding: [CGRect] = []
    ) -> (red: Bool, yellow: Bool, green: Bool, regions: [CGRect]) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            return (false, false, false, [])
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return (false, false, false, [])
        }

        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard chromaWidth > 0, chromaHeight > 0 else { return (false, false, false, []) }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // Fine grid over the top 60% — distant lamps span only a few chroma
        // pixels, so sample densely (~192 columns) to never step over one.
        let stepX = max(1, chromaWidth / 192)
        let stepY = max(1, chromaHeight / 108)
        let maxY = Int(Double(chromaHeight) * 0.60)

        // Per-color cluster statistics: a signal LAMP is a small, compact,
        // dense blob. Big areas (green highway signs, desert tan reading as
        // yellow) and scattered hits (foliage) are rejected on shape.
        struct ColorStat {
            var count = 0
            var minGX = Int.max, maxGX = -1, minGY = Int.max, maxGY = -1
            mutating func add(_ gx: Int, _ gy: Int) {
                count += 1
                minGX = min(minGX, gx); maxGX = max(maxGX, gx)
                minGY = min(minGY, gy); maxGY = max(maxGY, gy)
            }
        }
        var red = ColorStat()
        var yellow = ColorStat()
        var green = ColorStat()

        var gy = 0
        var y = 0
        while y < maxY {
            var gx = 0
            var x = 0
            while x < chromaWidth {
                let nx = Double(x) / Double(chromaWidth)
                let ny = Double(y) / Double(chromaHeight)
                if excluding.contains(where: { $0.contains(CGPoint(x: nx, y: ny)) }) {
                    x += stepX
                    gx += 1
                    continue
                }
                let cb = Int(chroma[y * chromaRowBytes + 2 * x])
                let cr = Int(chroma[y * chromaRowBytes + 2 * x + 1])
                let brightness = Int(luma[(2 * y) * lumaRowBytes + 2 * x])

                // Emissive-lamp bands.
                //
                // CRITICAL: traffic signal HOUSINGS are amber-painted metal
                // (Cr≈164, Cb≈62) and used to pass as "red". A true red lamp
                // is far deeper in red (Cr≈225) and much less blue-deficient
                // (Cb≈95) — the Cb floor is what separates lamp from paint.
                let isRed = cr >= 180 && cb >= 78 && cb <= 130 && brightness >= 50
                // Lit amber lamp: warm but not red-deep. Still overlaps amber
                // paint, so the shape gate below does the rest.
                let isYellow = !isRed && cr >= 150 && cr < 180 && cb <= 95 && brightness >= 120
                let isGreen = cr <= 112 && cb >= 95 && cb <= 155 && brightness >= 70
                    && (abs(cb - 128) + abs(cr - 128)) >= 24

                if isRed { red.add(gx, gy) }
                if isYellow { yellow.add(gx, gy) }
                if isGreen { green.add(gx, gy) }
                x += stepX
                gx += 1
            }
            y += stepY
            gy += 1
        }

        // Lamp-shape test: enough hits to be real, few enough to be a lamp
        // (not a sign face), a small bounding box, and dense within it.
        func isLamp(_ stat: ColorStat) -> Bool {
            guard stat.count >= 2, stat.count <= 60 else { return false }
            let cellsW = stat.maxGX - stat.minGX + 1
            let cellsH = stat.maxGY - stat.minGY + 1
            let widthN = Double(cellsW * stepX) / Double(chromaWidth)
            let heightN = Double(cellsH * stepY) / Double(chromaHeight)
            guard widthN <= 0.08, heightN <= 0.12 else { return false }
            // A lit lamp is roughly round; a whole signal housing is a tall
            // rectangle (three lamps high), so aspect ratio rejects paint.
            guard widthN > 0, heightN > 0 else { return false }
            let aspect = widthN / heightN
            guard aspect >= 0.45, aspect <= 2.2 else { return false }
            let density = Double(stat.count) / Double(cellsW * cellsH)
            return density >= 0.18
        }

        func region(_ stat: ColorStat) -> CGRect? {
            guard isLamp(stat) else { return nil }
            let padX = Double(stepX) / Double(chromaWidth) * 2
            let padY = Double(stepY) / Double(chromaHeight) * 2
            let minXn = Double(stat.minGX * stepX) / Double(chromaWidth)
            let minYn = Double(stat.minGY * stepY) / Double(chromaHeight)
            let maxXn = Double((stat.maxGX + 1) * stepX) / Double(chromaWidth)
            let maxYn = Double((stat.maxGY + 1) * stepY) / Double(chromaHeight)
            return CGRect(
                x: max(0, minXn - padX),
                y: max(0, minYn - padY),
                width: min(1, maxXn - minXn + 2 * padX),
                height: min(1, maxYn - minYn + 2 * padY)
            )
        }

        let regions = [region(red), region(yellow), region(green)].compactMap { $0 }
        return (isLamp(red), isLamp(yellow), isLamp(green), regions)
    }
}
