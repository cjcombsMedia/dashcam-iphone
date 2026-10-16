import XCTest
@testable import DashCamKit

/// The training console's numbers have to be provable, not decorative — they
/// are what gets pointed at when someone asks how the model is being taught.
final class TrainingConsoleTests: XCTestCase {
    private var workspace: Workspace!
    private var store: LabelStore!
    private var clip: Clip!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-training-\(UUID().uuidString)")
        workspace = Workspace(root: root)
        store = LabelStore(workspace: workspace)

        let dayFolder = root.appendingPathComponent("2026-08-11", isDirectory: true)
        try? FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dayFolder.appendingPathComponent("DC_train.mp4").path,
            contents: Data("v".utf8)
        )
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let sidecar = TelemetrySidecar(
            segmentFileName: "DC_train.mp4", resolution: "hd", startedAt: start,
            samples: (0..<20).map {
                TelemetrySample(
                    timestamp: start.addingTimeInterval(Double($0)),
                    latitude: 32.14, longitude: -110.76, altitude: 800,
                    speedMPS: 20, headingDegrees: 90, vibrationG: 0.02, thermal: "nominal"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(sidecar).write(to: dayFolder.appendingPathComponent("DC_train.json"))
        clip = workspace.clips().first
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace.root)
        super.tearDown()
    }

    private func review(_ verdicts: [(String, DetectionVerdict)]) {
        var review = store.loadReview(for: clip)
        review.reviews = verdicts.enumerated().map { index, pair in
            DetectionReview(
                detectionID: "d\(index)", verdict: pair.1,
                className: pair.0, value: nil, time: Double(index)
            )
        }
        store.saveReview(review, for: clip)
    }

    func testAccuracyIsConfirmedOverEverythingReviewed() {
        review([
            ("speed_limit", .confirmed), ("speed_limit", .confirmed),
            ("speed_limit", .rejected), ("speed_limit", .corrected),
        ])
        let summary = TrainingSummary.build(store: store)
        XCTAssertEqual(summary.totalReviewed, 4)
        XCTAssertEqual(summary.totalConfirmed, 2)
        XCTAssertEqual(summary.overallAccuracy, 0.5, accuracy: 0.001)
    }

    func testPerClassTalliesSeparateTheProblemClasses() {
        review([
            ("speed_limit", .confirmed), ("speed_limit", .confirmed),
            ("signal_red", .rejected), ("signal_red", .rejected), ("signal_red", .rejected),
        ])
        let summary = TrainingSummary.build(store: store)
        let speed = summary.byClass.first { $0.className == "speed_limit" }
        let signal = summary.byClass.first { $0.className == "signal_red" }
        XCTAssertEqual(speed?.accuracy ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(signal?.accuracy ?? 1, 0.0, accuracy: 0.001,
                       "A class that's always wrong must read 0% so it stands out")
        XCTAssertEqual(summary.byClass.first?.className, "signal_red",
                       "Most-reviewed class sorts first")
    }

    func testNothingReviewedIsZeroNotACrash() {
        let summary = TrainingSummary.build(store: store)
        XCTAssertEqual(summary.totalReviewed, 0)
        XCTAssertEqual(summary.overallAccuracy, 0)
        XCTAssertTrue(summary.byClass.isEmpty)
    }

    func testDrawnBoxesAreCounted() {
        var labels = store.load(for: clip)
        labels.labels = [
            FrameLabel(time: 1, className: "stop_sign", x: 0.1, y: 0.1, width: 0.1, height: 0.1),
            FrameLabel(time: 2, className: "stop_sign", x: 0.2, y: 0.2, width: 0.1, height: 0.1),
        ]
        store.save(labels, for: clip)
        XCTAssertEqual(TrainingSummary.build(store: store).boxesDrawn, 2)
    }

    // MARK: - The exchange log

    func testEventsPersistAcrossRestart() {
        let log = SyncLogStore(workspace: workspace)
        log.append(SyncEvent(
            at: Date(timeIntervalSince1970: 1_770_000_000), direction: .macToPhone,
            action: "GET /memory", summary: "Phone pulled 12 features", outcome: .ok,
            detail: ["features": "12"]
        ))

        // A fresh store, as after quitting and reopening Studio.
        let reopened = SyncLogStore(workspace: Workspace(root: workspace.root))
        let events = reopened.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "GET /memory")
        XCTAssertEqual(events.first?.detail["features"], "12",
                       "The detail is the evidence — it has to survive too")
    }

    func testTheLogIsCappedSoItCannotGrowForever() {
        let log = SyncLogStore(workspace: workspace)
        for index in 0..<(SyncLogStore.maxEvents + 25) {
            log.append(SyncEvent(
                at: Date(timeIntervalSince1970: TimeInterval(index)), direction: .local,
                action: "event \(index)", summary: "", outcome: .info
            ))
        }
        let events = log.events()
        XCTAssertEqual(events.count, SyncLogStore.maxEvents)
        XCTAssertEqual(events.last?.action, "event \(SyncLogStore.maxEvents + 24)",
                       "The newest must be kept; the oldest are dropped")
    }

    func testThePhoneReportRoundTrips() {
        let log = SyncLogStore(workspace: workspace)
        log.save(PhoneReport(
            at: Date(timeIntervalSince1970: 1_770_000_500),
            deviceName: "CJ's iPhone", appVersion: "1.0",
            featuresHeld: 42, imported: 7, skippedAlreadyKnown: 3,
            refusedForgotten: 1, unsupported: 0, tombstones: 2
        ))
        let report = SyncLogStore(workspace: Workspace(root: workspace.root)).latestReport()
        XCTAssertEqual(report?.imported, 7)
        XCTAssertEqual(report?.featuresHeld, 42)
        XCTAssertEqual(report?.refusedForgotten, 1)
    }
}
