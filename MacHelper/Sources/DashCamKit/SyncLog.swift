import Foundation

/// One exchange between DashCam Studio and the phone.
///
/// Training a model this way is a loop — you correct what the phone got
/// wrong, the corrections travel to the phone, the phone accepts or rejects
/// them, and the next drive is better. Every step of that loop is recorded
/// here so the whole thing can be watched rather than assumed.
public struct SyncEvent: Codable, Identifiable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        /// The phone asked the Mac for something.
        case phoneToMac
        /// The Mac produced something for the phone.
        case macToPhone
        /// Work done entirely on the Mac.
        case local
    }

    public enum Outcome: String, Codable, Sendable {
        case ok, rejected, failed, info
    }

    public var id: UUID
    public var at: Date
    public var direction: Direction
    /// What happened, e.g. "GET /memory", "Corrections exported".
    public var action: String
    /// One line a human can read.
    public var summary: String
    public var outcome: Outcome
    /// Payload counts, status codes, byte totals — whatever makes the event
    /// verifiable rather than merely claimed.
    public var detail: [String: String]

    public init(
        id: UUID = UUID(),
        at: Date,
        direction: Direction,
        action: String,
        summary: String,
        outcome: Outcome,
        detail: [String: String] = [:]
    ) {
        self.id = id
        self.at = at
        self.direction = direction
        self.action = action
        self.summary = summary
        self.outcome = outcome
        self.detail = detail
    }
}

/// What the phone reported back after acting on an export.
///
/// Without this the loop is one-way and unprovable: the Mac can say it sent
/// 40 features, but only the phone knows how many it actually took, how many
/// it already had, and how many it refused because they'd been removed.
public struct PhoneReport: Codable, Equatable, Sendable {
    public var at: Date
    public var deviceName: String
    public var appVersion: String
    /// Features the phone holds after the import.
    public var featuresHeld: Int
    public var imported: Int
    public var skippedAlreadyKnown: Int
    public var refusedForgotten: Int
    public var unsupported: Int
    /// Removals the phone has pushed up.
    public var tombstones: Int
    public var note: String?

    public init(
        at: Date, deviceName: String, appVersion: String,
        featuresHeld: Int, imported: Int, skippedAlreadyKnown: Int,
        refusedForgotten: Int, unsupported: Int, tombstones: Int, note: String? = nil
    ) {
        self.at = at
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.featuresHeld = featuresHeld
        self.imported = imported
        self.skippedAlreadyKnown = skippedAlreadyKnown
        self.refusedForgotten = refusedForgotten
        self.unsupported = unsupported
        self.tombstones = tombstones
        self.note = note
    }
}

/// Persists the exchange log and the phone's latest report.
///
/// Kept on disk rather than in memory so the record survives a restart —
/// a training history that vanishes when you quit the app proves nothing.
public final class SyncLogStore: @unchecked Sendable {
    /// Beyond this the file is trimmed oldest-first.
    public static let maxEvents = 2000

    private let workspace: Workspace
    private let lock = NSLock()

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public var eventsFile: URL { workspace.root.appendingPathComponent("synclog.json") }
    public var reportFile: URL { workspace.root.appendingPathComponent("phonereport.json") }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    public func events() -> [SyncEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: eventsFile) else { return [] }
        let (_, decoder) = Self.coder()
        return (try? decoder.decode([SyncEvent].self, from: data)) ?? []
    }

    @discardableResult
    public func append(_ event: SyncEvent) -> [SyncEvent] {
        lock.lock(); defer { lock.unlock() }
        let (encoder, decoder) = Self.coder()
        var all: [SyncEvent] = []
        if let data = try? Data(contentsOf: eventsFile) {
            all = (try? decoder.decode([SyncEvent].self, from: data)) ?? []
        }
        all.append(event)
        if all.count > Self.maxEvents {
            all.removeFirst(all.count - Self.maxEvents)
        }
        try? FileManager.default.createDirectory(
            at: workspace.root, withIntermediateDirectories: true
        )
        if let data = try? encoder.encode(all) {
            try? data.write(to: eventsFile, options: .atomic)
        }
        return all
    }

    public func latestReport() -> PhoneReport? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: reportFile) else { return nil }
        let (_, decoder) = Self.coder()
        return try? decoder.decode(PhoneReport.self, from: data)
    }

    public func save(_ report: PhoneReport) {
        lock.lock(); defer { lock.unlock() }
        let (encoder, _) = Self.coder()
        try? FileManager.default.createDirectory(
            at: workspace.root, withIntermediateDirectories: true
        )
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportFile, options: .atomic)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: eventsFile)
    }
}

// MARK: - Training summary

/// A tally of the corrections made across every clip — the thing you point
/// at when someone asks what "training the model" actually means.
public struct TrainingSummary: Equatable, Sendable {
    public struct ClassTally: Equatable, Identifiable, Sendable {
        public var id: String { className }
        public var className: String
        public var confirmed: Int
        public var corrected: Int
        public var rejected: Int

        public init(className: String, confirmed: Int, corrected: Int, rejected: Int) {
            self.className = className
            self.confirmed = confirmed
            self.corrected = corrected
            self.rejected = rejected
        }

        public var total: Int { confirmed + corrected + rejected }
        /// How often the phone was right about this class.
        public var accuracy: Double {
            total == 0 ? 0 : Double(confirmed) / Double(total)
        }
    }

    public var byClass: [ClassTally]
    public var clipsReviewed: Int
    public var boxesDrawn: Int
    public var featuresReadyToSend: Int

    public init(
        byClass: [ClassTally], clipsReviewed: Int,
        boxesDrawn: Int, featuresReadyToSend: Int
    ) {
        self.byClass = byClass
        self.clipsReviewed = clipsReviewed
        self.boxesDrawn = boxesDrawn
        self.featuresReadyToSend = featuresReadyToSend
    }

    public var totalReviewed: Int { byClass.reduce(0) { $0 + $1.total } }
    public var totalConfirmed: Int { byClass.reduce(0) { $0 + $1.confirmed } }
    public var totalCorrected: Int { byClass.reduce(0) { $0 + $1.corrected } }
    public var totalRejected: Int { byClass.reduce(0) { $0 + $1.rejected } }

    /// The headline number: how often the phone's detections were right.
    public var overallAccuracy: Double {
        totalReviewed == 0 ? 0 : Double(totalConfirmed) / Double(totalReviewed)
    }

    /// Builds the tally from everything on disk.
    public static func build(store: LabelStore) -> TrainingSummary {
        var tallies: [String: ClassTally] = [:]
        var clips = Set<String>()

        for (clip, review) in store.allReviews() {
            guard !review.reviews.isEmpty else { continue }
            clips.insert(clip.id)
            for entry in review.reviews {
                var tally = tallies[entry.className]
                    ?? ClassTally(className: entry.className, confirmed: 0, corrected: 0, rejected: 0)
                switch entry.verdict {
                case .confirmed: tally.confirmed += 1
                case .corrected: tally.corrected += 1
                case .rejected: tally.rejected += 1
                }
                tallies[entry.className] = tally
            }
        }

        let boxes = store.allLabels().reduce(0) { $0 + $1.labels.labels.count }
        return TrainingSummary(
            byClass: tallies.values.sorted { $0.total > $1.total },
            clipsReviewed: clips.count,
            boxesDrawn: boxes,
            featuresReadyToSend: 0
        )
    }
}
