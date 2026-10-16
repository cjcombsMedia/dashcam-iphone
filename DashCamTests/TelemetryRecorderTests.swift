import XCTest
@testable import DashCam

final class TelemetryRecorderTests: XCTestCase {
    func testCollectsRoughlyOneSamplePerSecond() {
        let recorder = TelemetryRecorder()
        var count = 0
        recorder.sampleProvider = {
            count += 1
            return TelemetrySample(timestamp: Date(), speedMPS: Double(count))
        }

        recorder.begin()
        var delivered: [TelemetrySample] = []
        recorder.onSample = { delivered.append($0) }
        let expectation = expectation(description: "samples collected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)

        recorder.end()
        XCTAssertTrue((1...3).contains(delivered.count), "Expected ~2 samples in 2.4 s, got \(delivered.count)")
        XCTAssertFalse(recorder.isRunning)
    }

    /// Regression: samples used to be held in the recorder until the NEXT
    /// segment started, which raced the sidecar write. Every sample must be
    /// handed out the instant it's taken, so it can be filed against the
    /// segment recording right now.
    func testEverySampleIsHandedOutImmediately() {
        let recorder = TelemetryRecorder()
        recorder.sampleProvider = { TelemetrySample(timestamp: Date()) }

        // Stands in for the view model's per-segment buckets.
        var currentSegment = "segment-A"
        var byFile: [String: [TelemetrySample]] = [:]
        recorder.onSample = { byFile[currentSegment, default: []].append($0) }

        recorder.begin()
        let first = expectation(description: "first segment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { first.fulfill() }
        waitForExpectations(timeout: 5)

        XCTAssertGreaterThanOrEqual(byFile["segment-A"]?.count ?? 0, 1,
                                    "Segment A's samples must already be filed, not waiting inside the recorder")

        // Rotate segments the way the capture service does.
        currentSegment = "segment-B"
        let second = expectation(description: "second segment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { second.fulfill() }
        waitForExpectations(timeout: 5)
        recorder.end()

        XCTAssertGreaterThanOrEqual(byFile["segment-B"]?.count ?? 0, 1,
                                    "Collection must continue across a segment rotation")
        XCTAssertTrue(recorder.isRunning == false)
    }

    /// `begin()` is called on every segment start; it must not restart or
    /// duplicate the timer, and must not drop the run in progress.
    func testBeginIsIdempotentAcrossSegmentStarts() {
        let recorder = TelemetryRecorder()
        recorder.sampleProvider = { TelemetrySample(timestamp: Date()) }
        var count = 0
        recorder.onSample = { _ in count += 1 }

        recorder.begin()
        recorder.begin()
        recorder.begin()

        let expectation = expectation(description: "ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { expectation.fulfill() }
        waitForExpectations(timeout: 5)
        recorder.end()

        XCTAssertTrue((1...2).contains(count),
                      "Three begin() calls must still produce one sample per second, got \(count)")
    }

    func testSidecarJSONShapeRoundTrips() throws {
        let recorder = TelemetryRecorder()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let samples = [
            TelemetrySample(
                timestamp: start,
                latitude: 37.7749,
                longitude: -122.4194,
                altitude: 16,
                speedMPS: 13.4,
                headingDegrees: 245
            ),
            TelemetrySample(timestamp: start.addingTimeInterval(1)),
        ]

        let expectation = expectation(description: "sidecar written")
        var writtenName: String?
        recorder.writeSidecar(
            samples: samples,
            segmentFileName: "DC_test_001.mov",
            resolution: .uhd4k,
            startedAt: start,
            directory: directory
        ) { name in
            writtenName = name
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)

        XCTAssertEqual(writtenName, "DC_test_001.json")
        let data = try Data(contentsOf: directory.appendingPathComponent("DC_test_001.json"))
        let decoded = try TelemetrySidecar.decoder().decode(TelemetrySidecar.self, from: data)

        XCTAssertEqual(decoded.segmentFileName, "DC_test_001.mov")
        XCTAssertEqual(decoded.resolution, "uhd4k")
        XCTAssertEqual(decoded.samples.count, 2)
        XCTAssertEqual(decoded.samples[0].latitude ?? 0, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(decoded.samples[0].speedMPS ?? 0, 13.4, accuracy: 0.0001)
        XCTAssertNil(decoded.samples[1].latitude, "Missing telemetry is omitted, not zero-filled")
    }
}
