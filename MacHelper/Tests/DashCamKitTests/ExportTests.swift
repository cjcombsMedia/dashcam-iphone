import XCTest
@testable import DashCamKit

final class SidecarTests: XCTestCase {
    private func makeSidecar() -> TelemetrySidecar {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let samples = (0..<10).map { second in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(second)),
                latitude: 32.14 + Double(second) * 0.0001,
                longitude: -110.76,
                altitude: 800,
                speedMPS: 20,
                headingDegrees: 90,
                vibrationG: 0.05,
                thermal: "nominal"
            )
        }
        return TelemetrySidecar(
            segmentFileName: "DC_test.mp4",
            resolution: "hd",
            startedAt: start,
            samples: samples
        )
    }

    func testSampleLookupPicksNearestSecond() {
        let sidecar = makeSidecar()
        let sample = sidecar.sample(atOffset: 4.4)
        XCTAssertEqual(sample?.latitude ?? 0, 32.14 + 4 * 0.0001, accuracy: 0.000001)
    }

    func testSampleLookupClampsPastEnd() {
        let sidecar = makeSidecar()
        let sample = sidecar.sample(atOffset: 999)
        XCTAssertEqual(sample?.latitude ?? 0, 32.14 + 9 * 0.0001, accuracy: 0.000001)
    }

    func testEmptySidecarReturnsNil() {
        let sidecar = TelemetrySidecar(
            segmentFileName: "x.mp4", resolution: "hd",
            startedAt: Date(), samples: []
        )
        XCTAssertNil(sidecar.sample(atOffset: 1))
    }
}

final class GeoHelperTests: XCTestCase {
    func testDistanceMatchesKnownSeparation() {
        // ~111 m per 0.001° of latitude.
        let metres = Exporters.distance(32.140, -110.760, 32.141, -110.760)
        XCTAssertEqual(metres, 111, accuracy: 3)
    }

    func testHeadingDeltaWrapsAroundNorth() {
        XCTAssertEqual(Exporters.headingDelta(350, 10), 20, accuracy: 0.0001)
        XCTAssertEqual(Exporters.headingDelta(90, 270), 180, accuracy: 0.0001)
    }
}

final class LabelStoreTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-tests-\(UUID().uuidString)")
        return Workspace(root: root)
    }

    func testClassesSeedWithDefaultsAndPersist() {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let store = LabelStore(workspace: workspace)

        let seeded = store.loadClasses()
        XCTAssertFalse(seeded.isEmpty)
        XCTAssertTrue(seeded.contains { $0.name == "construction_bollard" })
        XCTAssertTrue(seeded.contains { $0.name == "bike_lane_paint" })

        var custom = seeded
        custom.append(LabelClass(name: "test_class", display: "Test", color: "#FFFFFF", group: "Other"))
        store.saveClasses(custom)

        let reloaded = LabelStore(workspace: workspace).loadClasses()
        XCTAssertTrue(reloaded.contains { $0.name == "test_class" })
    }

    func testSignClassesMapToPhoneMemoryTypes() {
        let classes = DefaultClasses.all
        XCTAssertEqual(classes.first { $0.name == "speed_limit" }?.memoryType, "speedLimit")
        XCTAssertEqual(classes.first { $0.name == "fire_station_sign" }?.memoryType, "fireStation")
        // Obstacles are training-only: they have no place in road memory.
        XCTAssertNil(classes.first { $0.name == "traffic_cone" }?.memoryType)
    }
}
