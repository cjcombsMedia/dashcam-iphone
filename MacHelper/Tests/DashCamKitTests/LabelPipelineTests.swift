import XCTest
@testable import DashCamKit

/// Proves the label → GPS → road-memory pipeline the phone depends on, and
/// the crash-safety journal.
final class LabelPipelineTests: XCTestCase {
    private var workspace: Workspace!
    private var store: LabelStore!
    private var clip: Clip!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-pipeline-\(UUID().uuidString)")
        workspace = Workspace(root: root)
        store = LabelStore(workspace: workspace)

        // A clip with a telemetry sidecar, as the phone produces.
        let dayFolder = root.appendingPathComponent("2026-08-03", isDirectory: true)
        try? FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let videoURL = dayFolder.appendingPathComponent("DC_test.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: Data("video".utf8))

        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let samples = (0..<20).map { second in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(second)),
                latitude: 32.14 + Double(second) * 0.0002,
                longitude: -110.76,
                altitude: 800,
                speedMPS: 20,
                headingDegrees: 90,
                vibrationG: 0.04,
                thermal: "nominal"
            )
        }
        let sidecar = TelemetrySidecar(
            segmentFileName: "DC_test.mp4", resolution: "hd",
            startedAt: start, samples: samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sidecarURL = dayFolder.appendingPathComponent("DC_test.json")
        try? encoder.encode(sidecar).write(to: sidecarURL)

        clip = workspace.clips().first
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace.root)
        super.tearDown()
    }

    private func label(_ className: String, at time: Double, value: String? = nil) -> FrameLabel {
        FrameLabel(
            time: time, className: className,
            x: 0.4, y: 0.3, width: 0.1, height: 0.12, value: value
        )
    }

    // MARK: - Editing a label

    func testChangingAClassIsPersisted() {
        XCTAssertNotNil(clip)
        var labels = store.load(for: clip)
        var mislabelled = label("speed_limit", at: 5, value: "45")
        labels.labels.append(mislabelled)
        store.save(labels, for: clip)

        // The correction a user makes via the class picker / right-click.
        mislabelled.className = "crossing_sign"
        mislabelled.value = nil
        var updated = store.load(for: clip)
        updated.labels = [mislabelled]
        store.save(updated, for: clip)

        let reloaded = store.load(for: clip)
        XCTAssertEqual(reloaded.labels.count, 1)
        XCTAssertEqual(reloaded.labels.first?.className, "crossing_sign")
        XCTAssertNil(reloaded.labels.first?.value)
    }

    // MARK: - Crash safety

    func testJournalledEditsSurviveWithoutAnExplicitSave() {
        let added = label("stop_sign", at: 3)
        // Simulates a crash: journalled but never saved.
        store.appendJournal(.upsert, label: added, for: clip)

        let recovered = LabelStore(workspace: workspace).load(for: clip)
        XCTAssertEqual(recovered.labels.count, 1, "A journalled label must survive a crash")
        XCTAssertEqual(recovered.labels.first?.className, "stop_sign")
    }

    func testJournalledDeleteSurvives() {
        var labels = store.load(for: clip)
        let doomed = label("traffic_cone", at: 4)
        labels.labels.append(doomed)
        store.save(labels, for: clip)

        store.appendJournal(.delete, label: doomed, for: clip)

        let recovered = LabelStore(workspace: workspace).load(for: clip)
        XCTAssertTrue(recovered.labels.isEmpty, "A journalled delete must survive a crash")
    }

    func testSavingClearsTheJournal() {
        let added = label("yield_sign", at: 2)
        store.appendJournal(.upsert, label: added, for: clip)
        var labels = store.load(for: clip)      // folds the journal in
        store.save(labels, for: clip)           // and clears it
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL(for: clip).path))

        labels = store.load(for: clip)
        XCTAssertEqual(labels.labels.count, 1)
    }

    // MARK: - Label → road memory (what the phone recalls)

    func testSignLabelBecomesAGeoFeatureAtTheRightPlace() throws {
        var labels = store.load(for: clip)
        labels.labels = [label("speed_limit", at: 10, value: "45")]
        store.save(labels, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 1)

        let data = try Data(contentsOf: result.url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(RoadMemoryExport.self, from: data)

        let feature = try XCTUnwrap(export.features.first)
        XCTAssertEqual(feature.type, "speedLimit")
        XCTAssertEqual(feature.value, "45")
        XCTAssertEqual(feature.heading, 90, accuracy: 0.001)
        // The 10 s sample position, i.e. where the car actually was.
        XCTAssertEqual(feature.latitude, 32.14 + 10 * 0.0002, accuracy: 0.00001)
    }

    func testObstacleLabelsAreTrainingOnlyAndNeverBecomePlaces() throws {
        var labels = store.load(for: clip)
        labels.labels = [
            label("construction_bollard", at: 6),
            label("bike_lane_paint", at: 7),
        ]
        store.save(labels, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 0, "Cones and paint move — they must not be pinned to a map")
    }

    // MARK: - Reviewing the phone's own detections

    func testConfirmedDetectionBecomesAFeatureWithoutDrawingABox() throws {
        var review = store.loadReview(for: clip)
        review.reviews = [
            DetectionReview(
                detectionID: "speed-45-10", verdict: .confirmed,
                className: "speed_limit", value: "45", time: 10
            ),
        ]
        store.saveReview(review, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 1, "Confirming a detection should be enough to teach a place")
    }

    func testRejectedDetectionIsNeverExported() throws {
        var review = store.loadReview(for: clip)
        review.reviews = [
            DetectionReview(
                detectionID: "school-6", verdict: .rejected,
                className: "school_sign", value: nil, time: 6
            ),
        ]
        store.saveReview(review, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 0, "A false positive must never reach the phone")
    }

    func testCorrectedDetectionExportsTheCorrectedValue() throws {
        var review = store.loadReview(for: clip)
        review.reviews = [
            DetectionReview(
                detectionID: "speed-45-12", verdict: .corrected,
                className: "speed_limit", value: "25", time: 12
            ),
        ]
        store.saveReview(review, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        let data = try Data(contentsOf: result.url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(RoadMemoryExport.self, from: data)
        XCTAssertEqual(export.features.first?.value, "25")
    }

    func testDetectionsAreExtractedAndCollapsedFromASidecar() {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        // A 45 sign held on screen across many samples, then a school zone.
        var snapshots: [OverlaySnapshot] = (0..<10).map { index in
            OverlaySnapshot(offset: Double(index) * 0.5, speedLimit: 45)
        }
        snapshots.append(OverlaySnapshot(offset: 6, speedLimit: 45, schoolShowing: true, schoolSpeed: 15))
        snapshots.append(OverlaySnapshot(offset: 6.5, speedLimit: 45, schoolShowing: true, schoolSpeed: 15))

        let sidecar = TelemetrySidecar(
            segmentFileName: "DC_test.mp4", resolution: "hd", startedAt: start,
            samples: [], overlaySnapshots: snapshots,
            signalEvents: [SignalEvent(offset: 8, state: "red")],
            emergencyEvents: nil
        )

        let detections = DetectionExtractor.detections(from: sidecar)
        XCTAssertEqual(detections.filter { $0.className == "speed_limit" }.count, 1,
                       "A sign held on screen is one detection, not fifty")
        XCTAssertEqual(detections.filter { $0.className == "school_sign" }.count, 1)
        XCTAssertEqual(detections.filter { $0.className == "signal_red" }.count, 1)
        XCTAssertEqual(detections.first?.value, "45")
    }

    // MARK: - Deleting a clip's work

    func testDeletingAClipsWorkRemovesLabelsJournalAndReview() {
        var labels = store.load(for: clip)
        labels.labels = [label("stop_sign", at: 4)]
        store.save(labels, for: clip)
        store.appendJournal(.upsert, label: label("yield_sign", at: 5), for: clip)
        var review = store.loadReview(for: clip)
        review.reviews = [
            DetectionReview(detectionID: "x", verdict: .confirmed,
                            className: "speed_limit", value: "45", time: 4),
        ]
        store.saveReview(review, for: clip)

        store.deleteWork(for: clip)

        XCTAssertTrue(store.load(for: clip).labels.isEmpty, "Labels must be gone")
        XCTAssertTrue(store.loadReview(for: clip).reviews.isEmpty, "The review must be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL(for: clip).path),
                       "A leftover journal would resurrect deleted labels")
    }

    func testDeletedWorkNeverReachesTheExportedRoadMemory() throws {
        var labels = store.load(for: clip)
        labels.labels = [label("speed_limit", at: 10, value: "45")]
        store.save(labels, for: clip)
        XCTAssertEqual(try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 1)

        store.deleteWork(for: clip)
        XCTAssertEqual(try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 0)
    }

    // MARK: - Replaying the live screen

    /// A sidecar whose screen shows a 45 sign from 2 s, plus a school zone at
    /// 4 s, and emergency lights briefly at 6 s.
    private func screenSidecar() -> TelemetrySidecar {
        TelemetrySidecar(
            segmentFileName: "DC_test.mp4", resolution: "hd",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000), samples: [],
            overlaySnapshots: [
                OverlaySnapshot(offset: 2.0, speedLimit: 45),
                OverlaySnapshot(offset: 2.5, speedLimit: 45),
                OverlaySnapshot(offset: 4.0, speedLimit: 45, schoolShowing: true, schoolSpeed: 15),
            ],
            signalEvents: nil,
            emergencyEvents: [EmergencyEvent(offset: 6.0, x: 0.3, y: 0.2, width: 0.1, height: 0.08)]
        )
    }

    func testScreenIsCarriedForwardBetweenSamples() {
        let sidecar = screenSidecar()
        // Between the 2.0 and 2.5 samples the sign must stay on screen.
        XCTAssertEqual(sidecar.screen(atOffset: 2.3)?.speedLimit, 45)
        XCTAssertEqual(sidecar.screen(atOffset: 4.2)?.schoolShowing, true)
    }

    func testScreenIsBlankBeforeTheFirstSampleAndAfterItGoesStale() {
        let sidecar = screenSidecar()
        XCTAssertNil(sidecar.screen(atOffset: 1.0), "Nothing was on screen yet")
        XCTAssertNil(sidecar.screen(atOffset: 30.0), "The last screen must not hang forever")
    }

    func testEmergencyBoxAppearsOnlyAroundItsMoment() {
        let sidecar = screenSidecar()
        let box = sidecar.emergencyBox(atOffset: 6.2)
        XCTAssertEqual(box?.count, 4)
        XCTAssertEqual(box?[0] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertNil(sidecar.emergencyBox(atOffset: 3.0), "No lights were detected here")
    }

    func testRepeatedSightingsCollapseToOneFeature() throws {
        var labels = store.load(for: clip)
        // Same sign labelled on three nearby frames.
        labels.labels = [
            label("fire_station_sign", at: 8, value: "17"),
            label("fire_station_sign", at: 9, value: "17"),
            label("fire_station_sign", at: 10, value: "17"),
        ]
        store.save(labels, for: clip)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 1, "One real-world sign must yield one feature")
    }
}

/// A sign removed on the phone must stay removed. The Mac holds its own copy
/// of road memory, so without tombstones the next export hands the same wrong
/// sign straight back and the driver deletes it forever.
final class ForgottenFeatureTests: XCTestCase {
    private var workspace: Workspace!
    private var store: LabelStore!
    private var clip: Clip!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-forget-\(UUID().uuidString)")
        workspace = Workspace(root: root)
        store = LabelStore(workspace: workspace)

        let dayFolder = root.appendingPathComponent("2026-08-03", isDirectory: true)
        try? FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let videoURL = dayFolder.appendingPathComponent("DC_forget.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: Data("v".utf8))

        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let samples = (0..<20).map { second in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(second)),
                latitude: 32.14, longitude: -110.76, altitude: 800,
                speedMPS: 20, headingDegrees: 90, vibrationG: 0.02, thermal: "nominal"
            )
        }
        let sidecar = TelemetrySidecar(
            segmentFileName: "DC_forget.mp4", resolution: "hd",
            startedAt: start, samples: samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(sidecar).write(to: dayFolder.appendingPathComponent("DC_forget.json"))
        clip = workspace.clips().first
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace.root)
        super.tearDown()
    }

    private func labelASpeedLimit() {
        var labels = store.load(for: clip)
        labels.labels = [FrameLabel(
            time: 5, className: "speed_limit",
            x: 0.4, y: 0.3, width: 0.1, height: 0.1, value: "45"
        )]
        store.save(labels, for: clip)
    }

    func testALabelledSignExportsUntilItIsForgotten() throws {
        labelASpeedLimit()
        XCTAssertEqual(
            try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 1
        )

        // The driver long-presses it on the road; the phone posts this.
        try ForgottenStore.merge([
            ForgottenFeatureRecord(
                type: "speedLimit", latitude: 32.14, longitude: -110.76,
                heading: 90, forgottenAt: Date(timeIntervalSince1970: 1_770_000_100)
            ),
        ], in: workspace)

        XCTAssertEqual(
            try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 0,
            "A forgotten sign must never be exported back to the phone"
        )
    }

    func testForgettingOneSignLeavesOthersAlone() throws {
        var labels = store.load(for: clip)
        labels.labels = [
            FrameLabel(time: 5, className: "speed_limit",
                       x: 0.4, y: 0.3, width: 0.1, height: 0.1, value: "45"),
            FrameLabel(time: 5, className: "school_sign",
                       x: 0.6, y: 0.3, width: 0.1, height: 0.1, value: "15"),
        ]
        store.save(labels, for: clip)

        try ForgottenStore.merge([
            ForgottenFeatureRecord(type: "speedLimit", latitude: 32.14, longitude: -110.76,
                                   heading: 90, forgottenAt: Date()),
        ], in: workspace)

        let result = try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all)
        XCTAssertEqual(result.featureCount, 1, "Only the removed sign should disappear")
    }

    func testASignForgottenInOneDirectionSurvivesInTheOther() throws {
        labelASpeedLimit()
        // Removed for traffic heading west; we labelled it heading east.
        try ForgottenStore.merge([
            ForgottenFeatureRecord(type: "speedLimit", latitude: 32.14, longitude: -110.76,
                                   heading: 270, forgottenAt: Date()),
        ], in: workspace)

        XCTAssertEqual(
            try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 1,
            "Signs face one way — removing the westbound one must not remove the eastbound one"
        )
    }

    func testARemovalMilesAwayDoesNotApply() throws {
        labelASpeedLimit()
        try ForgottenStore.merge([
            ForgottenFeatureRecord(type: "speedLimit", latitude: 32.20, longitude: -110.76,
                                   heading: 90, forgottenAt: Date()),
        ], in: workspace)

        XCTAssertEqual(
            try Exporters.exportRoadMemory(store: store, classes: DefaultClasses.all).featureCount, 1
        )
    }

    func testTheSameRemovalSentTwiceIsStoredOnce() throws {
        let record = ForgottenFeatureRecord(
            type: "stop", latitude: 32.14, longitude: -110.76,
            heading: 90, forgottenAt: Date(timeIntervalSince1970: 1_770_000_100)
        )
        XCTAssertEqual(try ForgottenStore.merge([record], in: workspace), 1)
        XCTAssertEqual(try ForgottenStore.merge([record], in: workspace), 1,
                       "Re-sending after a failed sync must not pile up duplicates")
    }

    func testRemovalsSurviveARestart() throws {
        try ForgottenStore.merge([
            ForgottenFeatureRecord(type: "yield", latitude: 32.14, longitude: -110.76,
                                   heading: 90, forgottenAt: Date()),
        ], in: workspace)

        let reloaded = ForgottenStore.load(from: Workspace(root: workspace.root))
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.type, "yield")
    }
}
