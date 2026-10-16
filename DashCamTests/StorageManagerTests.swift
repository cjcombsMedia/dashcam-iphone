import XCTest
@testable import DashCam

final class StorageManagerTests: XCTestCase {
    private var fs: MockFileSystem!
    private var manager: StorageManager!
    private let root = URL(fileURLWithPath: "/app")

    private let MB: Int64 = 1_000_000

    override func setUp() {
        super.setUp()
        fs = MockFileSystem()
        manager = StorageManager(rootURL: root, fileSystem: fs)
        try? manager.ensureFolders()
    }

    private func addLoop(_ name: String, sizeMB: Int64, age: TimeInterval) {
        fs.addFile(
            manager.url(forFileName: name, in: .loop),
            size: sizeMB * MB,
            createdAt: Date(timeIntervalSinceNow: -age)
        )
    }

    private func addSaved(_ name: String, sizeMB: Int64) {
        fs.addFile(
            manager.url(forFileName: name, in: .saved),
            size: sizeMB * MB,
            createdAt: Date()
        )
    }

    // MARK: - 75% budget + oldest-first pruning

    func testPrunesOldestLoopSegmentsFirstAndNeverTouchesSaved() throws {
        addLoop("a.mov", sizeMB: 100, age: 3000)
        addLoop("b.mov", sizeMB: 200, age: 2000)
        addLoop("c.mov", sizeMB: 100, age: 1000)
        fs.addFile(
            manager.url(forFileName: "a.json", in: .loop),
            size: 1 * MB,
            createdAt: Date(timeIntervalSinceNow: -3000)
        )
        addSaved("keep.mov", sizeMB: 100)
        fs.freeSpaceValue = 99 * MB

        // footage=501, free=99 → allowed = 0.75 * 600 = 450.
        // 501 + 100 (estimate) > 450 → prune a (+ sidecar), then b.
        let result = try manager.prepareForNextSegment(estimatedBytes: 100 * MB)

        XCTAssertEqual(result, .ready(prunedFiles: ["a.mov", "b.mov"]))
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "a.mov", in: .loop)))
        XCTAssertFalse(
            fs.hasFile(manager.url(forFileName: "a.json", in: .loop)),
            "The pruned segment's telemetry sidecar must be deleted with it"
        )
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "b.mov", in: .loop)))
        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "c.mov", in: .loop)))
        XCTAssertTrue(
            fs.hasFile(manager.url(forFileName: "keep.mov", in: .saved)),
            "SAVED must never be auto-deleted"
        )
    }

    func testNoPruningWhenBudgetHasRoom() throws {
        addLoop("a.mov", sizeMB: 100, age: 1000)
        fs.freeSpaceValue = 10_000 * MB

        let result = try manager.prepareForNextSegment(estimatedBytes: 300 * MB)

        XCTAssertEqual(result, .ready(prunedFiles: []))
        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "a.mov", in: .loop)))
    }

    func testStopsRecordingWhenEvenEmptyLoopCannotFit() throws {
        addSaved("big.mov", sizeMB: 900)
        fs.freeSpaceValue = 100 * MB

        // allowed = 0.75 * 1000 = 750; saved alone (900) already exceeds it.
        let result = try manager.prepareForNextSegment(estimatedBytes: 100 * MB)

        XCTAssertEqual(result, .stopRecording)
        XCTAssertTrue(
            fs.hasFile(manager.url(forFileName: "big.mov", in: .saved)),
            "Stopping must not delete SAVED footage"
        )
    }

    func testDrainsLoopThenStopsWhenSavedDominates() throws {
        addLoop("old.mov", sizeMB: 50, age: 1000)
        addSaved("big.mov", sizeMB: 900)
        fs.freeSpaceValue = 50 * MB

        // allowed = 0.75 * (50 + 950) = 750. Pruning the whole loop still
        // leaves saved (900) over budget → stop, loop emptied along the way.
        let result = try manager.prepareForNextSegment(estimatedBytes: 100 * MB)

        XCTAssertEqual(result, .stopRecording)
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "old.mov", in: .loop)))
        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "big.mov", in: .saved)))
    }

    // MARK: - Debug full-disk simulation

    func testSimulatedFullDiskClampsFreeSpace() throws {
        addLoop("a.mov", sizeMB: 100, age: 2000)
        addLoop("b.mov", sizeMB: 100, age: 1000)
        fs.freeSpaceValue = 100_000 * MB
        manager.simulatedFreeSpace = 0

        // allowed = 0.75 * (0 + 200) = 150 → estimate 50 forces pruning a
        // (100 remaining + 50 = 150 fits exactly; b survives).
        let result = try manager.prepareForNextSegment(estimatedBytes: 50 * MB)

        XCTAssertEqual(result, .ready(prunedFiles: ["a.mov"]))
        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "b.mov", in: .loop)))
    }

    // MARK: - Low loop capacity warning

    func testLowLoopCapacityWarningWhenSavedSqueezesLoop() {
        fs.freeSpaceValue = 2_000 * MB

        // allowed = 1500 MB → ~18 min at HD (~1.37 MB/s) < 30 min.
        XCTAssertTrue(manager.isLoopCapacityLow(resolution: .hd))

        fs.freeSpaceValue = 10_000 * MB
        // allowed = 7500 MB → ~91 min at HD.
        XCTAssertFalse(manager.isLoopCapacityLow(resolution: .hd))
    }

    func testEstimatedLoopMinutesSubtractsSavedFootage() {
        fs.freeSpaceValue = 10_000 * MB
        let before = manager.estimatedLoopMinutes(resolution: .hd)

        addSaved("big.mov", sizeMB: 4_000)
        let after = manager.estimatedLoopMinutes(resolution: .hd)

        XCTAssertLessThan(after, before)
    }

    // MARK: - Moves

    func testMoveToSavedMovesVideoAndSidecar() throws {
        addLoop("clip.mov", sizeMB: 100, age: 100)
        fs.addFile(manager.url(forFileName: "clip.json", in: .loop), size: 1, createdAt: Date())

        try manager.moveToSaved(fileName: "clip.mov", sidecarFileName: "clip.json")

        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "clip.mov", in: .saved)))
        XCTAssertTrue(fs.hasFile(manager.url(forFileName: "clip.json", in: .saved)))
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "clip.mov", in: .loop)))
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "clip.json", in: .loop)))
    }

    func testDeleteRemovesVideoAndSidecar() throws {
        addSaved("clip.mov", sizeMB: 100)
        fs.addFile(manager.url(forFileName: "clip.json", in: .saved), size: 1, createdAt: Date())

        try manager.delete(fileName: "clip.mov", sidecarFileName: "clip.json", from: .saved)

        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "clip.mov", in: .saved)))
        XCTAssertFalse(fs.hasFile(manager.url(forFileName: "clip.json", in: .saved)))
    }
}
