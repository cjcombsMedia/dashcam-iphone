import XCTest
@testable import DashCamKit

/// The palette is the vocabulary of the whole training effort — a duplicate
/// or mistyped class name silently splits a class in the dataset.
final class LabelPaletteTests: XCTestCase {

    func testClassNamesAreUnique() {
        let names = DefaultClasses.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "A duplicate name would split one class across two palette entries")
    }

    func testMachineNamesAreDatasetSafe() {
        for item in DefaultClasses.all {
            XCTAssertFalse(item.name.isEmpty)
            XCTAssertEqual(item.name, item.name.lowercased(),
                           "\(item.name) must be lowercase for Create ML")
            XCTAssertNil(item.name.rangeOfCharacter(from: .whitespaces),
                         "\(item.name) must not contain spaces")
        }
    }

    func testEveryMemoryTypeMatchesSomethingThePhoneUnderstands() {
        // Mirrors RoadFeatureType on the phone. A typo here means the export
        // silently drops that feature.
        let known: Set<String> = [
            "speedLimit", "school", "hump", "hospital", "bike", "city",
            "fireStation", "stop", "yield", "railroad", "pedestrianCrossing",
            "doNotEnter", "lowClearance",
        ]
        for item in DefaultClasses.all {
            if let memoryType = item.memoryType {
                XCTAssertTrue(known.contains(memoryType),
                              "\(item.name) maps to unknown memory type \(memoryType)")
            }
        }
    }

    // MARK: - Countries

    func testMexicanSignsAreHiddenWhenLabellingTheUS() {
        let alto = DefaultClasses.all.first { $0.name == "alto_sign" }
        XCTAssertEqual(alto?.region, .mexico)
        XCTAssertFalse(alto!.region.applies(to: .unitedStates))
        XCTAssertTrue(alto!.region.applies(to: .mexico))
        XCTAssertTrue(alto!.region.applies(to: .both), "The All filter shows everything")
    }

    func testInterstateShieldsAreHiddenWhenLabellingMexico() {
        let shield = DefaultClasses.all.first { $0.name == "interstate_shield" }
        XCTAssertEqual(shield?.region, .unitedStates)
        XCTAssertFalse(shield!.region.applies(to: .mexico))
    }

    func testUniversalClassesShowInBothCountries() {
        for name in ["pothole", "pedestrian", "traffic_cone", "signal_red"] {
            let item = DefaultClasses.all.first { $0.name == name }
            XCTAssertEqual(item?.region, .both, "\(name) is not country-specific")
            XCTAssertTrue(item!.region.applies(to: .unitedStates))
            XCTAssertTrue(item!.region.applies(to: .mexico))
        }
    }

    func testBothCountriesHaveAUsableVocabulary() {
        for country in [SignRegion.unitedStates, .mexico] {
            let available = DefaultClasses.all.filter { $0.region.applies(to: country) }
            XCTAssertGreaterThan(available.count, 40,
                                 "\(country.label) must have a full palette, not a handful")
        }
    }

    // MARK: - Coverage of the signage the owner photographed

    func testTheHighwaySignsFromTheRoadAreAllInThePalette() {
        let required = [
            "bridge_clearance_sign",   // 15 FT 9 IN
            "exit_panel", "exit_number_tab",
            "interstate_shield", "direction_banner",
            "services_panel", "gas_sign", "food_sign",
            "landmark_sign", "museum_sign",
            "speed_reduced_sign",
            "merge_sign", "added_lane_sign",
            "toll_road_sign", "state_route_shield",
            "billboard",
        ]
        let names = Set(DefaultClasses.all.map(\.name))
        for name in required {
            XCTAssertTrue(names.contains(name), "Missing palette class: \(name)")
        }
    }

    func testMexicanEquivalentsExistForTheCoreRegulatorySigns() {
        let names = Set(DefaultClasses.all.map(\.name))
        for name in ["alto_sign", "ceda_el_paso_sign", "velocidad_maxima_sign",
                     "tope_sign", "cuota_sign", "libre_sign", "altura_libre_sign"] {
            XCTAssertTrue(names.contains(name), "Missing Mexican class: \(name)")
        }
    }

    func testBillboardsAreLabellableSoTheDetectorLearnsToIgnoreThem() {
        let billboard = DefaultClasses.all.first { $0.name == "billboard" }
        XCTAssertEqual(billboard?.group, "Ignore")
        XCTAssertNil(billboard?.memoryType,
                     "An advert must never become a place the phone remembers")
    }

    // MARK: - Upgrading an existing workspace

    func testNewBuiltInClassesAppearWithoutLosingCustomOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-palette-\(UUID().uuidString)")
        let workspace = Workspace(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // An old classes.json: a few built-ins plus one the user added, and
        // no `region` key at all.
        let old = """
        [
          {"name":"stop_sign","display":"Stop","color":"#C70D0D","group":"Signs","hasValue":false},
          {"name":"my_custom_thing","display":"Custom","color":"#123456","group":"Obstacles","hasValue":false}
        ]
        """
        try old.write(to: workspace.classesFile, atomically: true, encoding: .utf8)

        let loaded = LabelStore(workspace: workspace).loadClasses()
        let names = Set(loaded.map(\.name))

        XCTAssertTrue(names.contains("my_custom_thing"), "A user's own class must survive")
        XCTAssertTrue(names.contains("interstate_shield"), "New built-ins must be folded in")
        XCTAssertEqual(loaded.first { $0.name == "stop_sign" }?.region, .both,
                       "A class with no region key must default rather than fail to decode")
    }

    func testLoadingTwiceDoesNotDuplicate() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashcam-palette-\(UUID().uuidString)")
        let workspace = Workspace(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LabelStore(workspace: workspace)
        let first = store.loadClasses()
        let second = store.loadClasses()
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(Set(second.map(\.name)).count, second.count)
    }
}
