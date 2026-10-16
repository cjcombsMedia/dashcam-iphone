import SwiftData
import XCTest
@testable import DashCam

@MainActor
final class TagStoreTests: XCTestCase {
    // Retained for the test's lifetime — a ModelContext must not outlive
    // its container.
    private var container: ModelContainer!

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ClipSegment.self, TagMark.self, SessionLog.self,
            configurations: config
        )
        return container.mainContext
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func pending(offset: Double) -> PendingTag {
        PendingTag(
            timestamp: Date(),
            offsetInClip: offset,
            latitude: 37.0,
            longitude: -122.0,
            speedMPS: 20,
            source: .manual
        )
    }

    func testTagOffsetsClampToEncodedDurationAndSegmentMovesToSaved() throws {
        let fs = MockFileSystem()
        let storage = StorageManager(rootURL: URL(fileURLWithPath: "/app"), fileSystem: fs)
        try storage.ensureFolders()
        fs.addFile(storage.url(forFileName: "clip.mov", in: .loop), size: 100, createdAt: Date())

        let tagStore = TagStore(storage: storage)
        let context = try makeContext()

        // A tag placed in the final moment can carry a wall-clock offset just
        // past the encoded (PTS) duration; it must clamp onto the timeline.
        let result = CaptureService.SegmentResult(
            url: storage.url(forFileName: "clip.mov", in: .loop),
            fileName: "clip.mov",
            startedAt: Date(),
            duration: 179.5,
            resolution: .hd,
            fileSize: 100,
            isFinal: false
        )
        let clip = tagStore.registerSegment(
            result: result,
            sidecarFileName: nil,
            pendingTags: [pending(offset: 181.2), pending(offset: 60.0)],
            context: context
        )

        let offsets = clip.tags.map(\.offsetInClip).sorted()
        XCTAssertEqual(offsets.count, 2)
        XCTAssertEqual(offsets[0], 60.0, accuracy: 0.001)
        XCTAssertEqual(offsets[1], 179.5, accuracy: 0.001, "Offset past the end must clamp to the duration")

        XCTAssertEqual(clip.folder, .saved, "Tagged segments move to SAVED")
        XCTAssertTrue(fs.hasFile(storage.url(forFileName: "clip.mov", in: .saved)))
        XCTAssertFalse(fs.hasFile(storage.url(forFileName: "clip.mov", in: .loop)))
    }

    func testUntaggedSegmentStaysInLoop() throws {
        let fs = MockFileSystem()
        let storage = StorageManager(rootURL: URL(fileURLWithPath: "/app"), fileSystem: fs)
        try storage.ensureFolders()
        fs.addFile(storage.url(forFileName: "clip.mov", in: .loop), size: 100, createdAt: Date())

        let tagStore = TagStore(storage: storage)
        let context = try makeContext()

        let result = CaptureService.SegmentResult(
            url: storage.url(forFileName: "clip.mov", in: .loop),
            fileName: "clip.mov",
            startedAt: Date(),
            duration: 180,
            resolution: .hd,
            fileSize: 100,
            isFinal: false
        )
        let clip = tagStore.registerSegment(
            result: result,
            sidecarFileName: nil,
            pendingTags: [],
            context: context
        )

        XCTAssertEqual(clip.folder, .loop)
        XCTAssertTrue(fs.hasFile(storage.url(forFileName: "clip.mov", in: .loop)))
    }
}
