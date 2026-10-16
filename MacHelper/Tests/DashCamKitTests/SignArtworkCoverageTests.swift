import XCTest
@testable import DashCamKit

/// The palette artwork is generated from class names, so a renamed or new
/// class silently loses its sign and falls back to a plain plaque. These
/// tests pin the names the artwork keys off.
final class SignArtworkCoverageTests: XCTestCase {

    /// Every class name the Studio artwork draws a specific face for.
    /// Kept here rather than in the Studio target because the test bundle
    /// builds against DashCamKit — the value is catching a rename of a
    /// class this list depends on.
    private let namesWithArtwork = [
        "stop_sign", "alto_sign", "yield_sign", "ceda_el_paso_sign",
        "do_not_enter_sign", "wrong_way_sign", "one_way_sign", "no_rebase_sign",
        "no_turn_on_red_sign", "keep_right_sign",
        "speed_limit", "velocidad_maxima_sign",
        "school_sign", "escuela_sign", "pedestrian_crossing_sign", "crossing_sign",
        "railroad_sign", "hump_sign", "tope_sign", "curve_warning_sign",
        "curva_peligrosa_sign", "signal_ahead_sign", "stop_ahead_sign",
        "merge_sign", "added_lane_sign", "lane_ends_sign", "lane_shift_sign",
        "speed_reduced_sign", "narrow_bridge_sign", "school_bus_stop_sign",
        "bridge_clearance_sign", "altura_libre_sign", "weight_limit_sign",
        "hospital_sign", "bike_route_sign", "fire_station_sign", "city_limit_sign",
        "bus_stop_sign", "bus_lane_sign", "brt_station_sign", "taxi_stand_sign",
        "metro_station_sign", "tram_station_sign", "train_station_sign",
        "airport_sign", "bike_share_sign", "pedestrian_zone_sign",
        "disabled_parking_sign", "loading_zone_sign",
        "parking_sign", "estacionamiento_sign", "no_parking_sign",
        "no_estacionarse_sign", "tow_away_sign",
        "interstate_shield", "us_route_shield", "state_route_shield",
        "business_route_shield", "county_route_shield", "mex_federal_shield",
        "mex_state_shield", "toll_road_sign", "cuota_sign", "libre_sign",
        "toll_booth_sign", "express_lane_sign", "direction_banner",
        "exit_panel", "exit_number_tab", "salida_panel",
        "signal_red", "signal_yellow", "signal_green", "signal_arrow",
        "billboard", "business_sign",
    ]

    func testEveryDrawnSignStillExistsInThePalette() {
        let palette = Set(DefaultClasses.all.map(\.name))
        for name in namesWithArtwork {
            XCTAssertTrue(
                palette.contains(name),
                "\(name) has artwork but is no longer a class — the drawing is now dead code"
            )
        }
    }

    /// The bus stop that started this: it must exist, be Transit, and be
    /// offered when labelling Mexico.
    func testTheMexicoCityBusStopIsAFirstClassSign() {
        let busStop = DefaultClasses.all.first { $0.name == "bus_stop_sign" }
        XCTAssertNotNil(busStop)
        XCTAssertEqual(busStop?.group, "Transit")
        XCTAssertTrue(busStop!.region.applies(to: .mexico))
        XCTAssertTrue(busStop!.region.applies(to: .unitedStates),
                      "Bus stops exist in both countries")
    }

    /// Classes with no real-world sign (a pothole, a pedestrian) correctly
    /// have no artwork entry — they get a plain plaque, which is honest.
    func testThingsThatAreNotSignsHaveNoSignArtwork() {
        let drawn = Set(namesWithArtwork)
        for name in ["pothole", "pedestrian", "debris", "bike_lane_paint", "traffic_cone"] {
            XCTAssertFalse(drawn.contains(name),
                           "\(name) is not a sign and must not be drawn as one")
        }
    }

    /// A reasonable share of the palette should be recognisable at a glance,
    /// otherwise the artwork isn't earning its place.
    func testMostSignClassesAreDrawn() {
        let signGroups = ["Signs", "Signals", "Routes", "Guide", "Transit", "Lane & clearance"]
        let signClasses = DefaultClasses.all.filter { signGroups.contains($0.group) }
        let drawn = Set(namesWithArtwork)
        let covered = signClasses.filter { drawn.contains($0.name) }.count
        let fraction = Double(covered) / Double(signClasses.count)
        XCTAssertGreaterThan(fraction, 0.75,
                             "Only \(covered)/\(signClasses.count) sign classes have artwork")
    }
}
