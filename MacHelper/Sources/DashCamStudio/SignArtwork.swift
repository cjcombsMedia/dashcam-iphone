import DashCamKit
import SwiftUI

/// Draws each label class as the sign it actually is.
///
/// A palette of 116 identical colour squares makes you read every row. Real
/// shapes make it scannable — an octagon is stop before you've read a word,
/// a brown rectangle is a landmark, a blue square with a bus is a bus stop.
/// Shape and colour are how signs work on the road; the palette should work
/// the same way.
///
/// The face is derived from the class name rather than stored on the class,
/// so adding a class stays a one-line data change and never requires new
/// artwork to be wired up — anything unrecognised falls back to a plain
/// coloured plaque in the class's own colour.

// MARK: - Outlines

struct SignOctagon: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 + .pi / 8
            let point = CGPoint(
                x: centre.x + radius * cos(angle),
                y: centre.y + radius * sin(angle)
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

struct SignInvertedTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SignDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct SignPentagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.32))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.32))
        path.closeSubpath()
        return path
    }
}

/// The interstate shield: flat top, flared shoulders, pointed base.
struct SignShield: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.94, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.44))
        path.addQuadCurve(to: CGPoint(x: w * 0.5, y: h),
                          control: CGPoint(x: w * 0.80, y: h * 0.84))
        path.addQuadCurve(to: CGPoint(x: w * 0.12, y: h * 0.44),
                          control: CGPoint(x: w * 0.20, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.12))
        path.closeSubpath()
        return path
    }
}

// MARK: - Face description

/// How one class should be drawn.
struct SignFace {
    enum Outline {
        case octagon, invertedTriangle, diamond, pentagon, circle
        case rectangle, wideRectangle, shield, square
    }

    enum Glyph {
        case none
        case symbol(String)
        case text(String)
    }

    var outline: Outline
    var fill: Color
    var border: Color
    var glyph: Glyph
    var glyphColor: Color
    /// A red bar through the face — the "prohibited" overlay.
    var slashed: Bool = false

    // Palette, matching the MUTCD and Mexican SCT colours.
    static let red = Color(red: 0.78, green: 0.06, blue: 0.18)
    static let yellow = Color(red: 1.0, green: 0.79, blue: 0.0)
    static let fluorescent = Color(red: 0.81, green: 1.0, blue: 0.11)
    static let green = Color(red: 0.0, green: 0.42, blue: 0.28)
    static let blue = Color(red: 0.0, green: 0.29, blue: 0.53)
    static let brown = Color(red: 0.38, green: 0.24, blue: 0.13)
    static let orange = Color(red: 0.96, green: 0.42, blue: 0.0)

    /// Works out the face for a class. Specific names first, then whole
    /// families by group, then a plain plaque.
    static func face(for item: LabelClass) -> SignFace {
        if let known = byName[item.name] { return known }
        return byGroup(item)
    }

    // MARK: Named signs

    private static let byName: [String: SignFace] = [
        // Regulatory
        "stop_sign": .init(outline: .octagon, fill: red, border: .white,
                           glyph: .text("STOP"), glyphColor: .white),
        "alto_sign": .init(outline: .octagon, fill: red, border: .white,
                           glyph: .text("ALTO"), glyphColor: .white),
        "yield_sign": .init(outline: .invertedTriangle, fill: .white, border: red,
                            glyph: .none, glyphColor: red),
        "ceda_el_paso_sign": .init(outline: .invertedTriangle, fill: .white, border: red,
                                   glyph: .none, glyphColor: red),
        "do_not_enter_sign": .init(outline: .circle, fill: red, border: .white,
                                   glyph: .none, glyphColor: .white, slashed: true),
        "wrong_way_sign": .init(outline: .rectangle, fill: red, border: .white,
                                glyph: .text("WW"), glyphColor: .white),
        "one_way_sign": .init(outline: .wideRectangle, fill: .black, border: .white,
                              glyph: .symbol("arrow.right"), glyphColor: .white),
        "no_rebase_sign": .init(outline: .circle, fill: .white, border: red,
                                glyph: .symbol("car.2.fill"), glyphColor: .black, slashed: true),
        "no_turn_on_red_sign": .init(outline: .rectangle, fill: .white, border: .black,
                                     glyph: .text("NTOR"), glyphColor: .black),
        "keep_right_sign": .init(outline: .rectangle, fill: .black, border: .white,
                                 glyph: .symbol("arrow.turn.up.right"), glyphColor: .white),

        // Speed
        "speed_limit": .init(outline: .rectangle, fill: .white, border: .black,
                             glyph: .text("55"), glyphColor: .black),
        "velocidad_maxima_sign": .init(outline: .rectangle, fill: .white, border: red,
                                       glyph: .text("80"), glyphColor: .black),

        // Warning
        "school_sign": .init(outline: .pentagon, fill: fluorescent, border: .black,
                             glyph: .symbol("figure.walk"), glyphColor: .black),
        "escuela_sign": .init(outline: .pentagon, fill: fluorescent, border: .black,
                              glyph: .symbol("figure.walk"), glyphColor: .black),
        "pedestrian_crossing_sign": .init(outline: .diamond, fill: fluorescent, border: .black,
                                          glyph: .symbol("figure.walk"), glyphColor: .black),
        "crossing_sign": .init(outline: .diamond, fill: yellow, border: .black,
                               glyph: .symbol("figure.walk"), glyphColor: .black),
        "railroad_sign": .init(outline: .circle, fill: yellow, border: .black,
                               glyph: .symbol("xmark"), glyphColor: .black),
        "hump_sign": .init(outline: .diamond, fill: yellow, border: .black,
                           glyph: .symbol("arrow.up.and.down"), glyphColor: .black),
        "tope_sign": .init(outline: .diamond, fill: yellow, border: .black,
                           glyph: .symbol("arrow.up.and.down"), glyphColor: .black),
        "curve_warning_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                    glyph: .symbol("arrow.turn.right.up"), glyphColor: .black),
        "curva_peligrosa_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                      glyph: .symbol("arrow.turn.right.up"), glyphColor: .black),
        "signal_ahead_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                   glyph: .symbol("light.beacon.max.fill"), glyphColor: .black),
        "stop_ahead_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                 glyph: .symbol("octagon.fill"), glyphColor: .black),
        "merge_sign": .init(outline: .diamond, fill: yellow, border: .black,
                            glyph: .symbol("arrow.triangle.merge"), glyphColor: .black),
        "added_lane_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                 glyph: .symbol("arrow.triangle.branch"), glyphColor: .black),
        "lane_ends_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                glyph: .symbol("arrow.merge"), glyphColor: .black),
        "lane_shift_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                 glyph: .symbol("arrow.turn.right.up"), glyphColor: .black),
        "speed_reduced_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                    glyph: .text("SLOW"), glyphColor: .black),
        "narrow_bridge_sign": .init(outline: .diamond, fill: yellow, border: .black,
                                    glyph: .symbol("arrow.left.and.right"), glyphColor: .black),
        "school_bus_stop_sign": .init(outline: .pentagon, fill: fluorescent, border: .black,
                                      glyph: .symbol("bus.fill"), glyphColor: .black),

        // Clearance & limits
        "bridge_clearance_sign": .init(outline: .wideRectangle, fill: green, border: .white,
                                       glyph: .text("15'9\""), glyphColor: .white),
        "altura_libre_sign": .init(outline: .wideRectangle, fill: .white, border: .black,
                                   glyph: .text("4.5m"), glyphColor: .black),
        "weight_limit_sign": .init(outline: .rectangle, fill: .white, border: .black,
                                   glyph: .symbol("scalemass.fill"), glyphColor: .black),

        // Service panels
        "hospital_sign": .init(outline: .square, fill: blue, border: .white,
                               glyph: .text("H"), glyphColor: .white),
        "bike_route_sign": .init(outline: .rectangle, fill: green, border: .white,
                                 glyph: .symbol("bicycle"), glyphColor: .white),
        "fire_station_sign": .init(outline: .rectangle, fill: red, border: .white,
                                   glyph: .symbol("flame.fill"), glyphColor: .white),
        "city_limit_sign": .init(outline: .wideRectangle, fill: green, border: .white,
                                 glyph: .symbol("signpost.right.fill"), glyphColor: .white),

        // Transit — the Mexico City bus stop and its relatives
        "bus_stop_sign": .init(outline: .square, fill: blue, border: .white,
                               glyph: .symbol("bus.fill"), glyphColor: .white),
        "bus_lane_sign": .init(outline: .square, fill: blue, border: .white,
                               glyph: .symbol("bus"), glyphColor: .white),
        "brt_station_sign": .init(outline: .square, fill: blue, border: .white,
                                  glyph: .symbol("bus.doubledecker.fill"), glyphColor: .white),
        "taxi_stand_sign": .init(outline: .square, fill: blue, border: .white,
                                 glyph: .symbol("car.fill"), glyphColor: .white),
        "metro_station_sign": .init(outline: .square, fill: orange, border: .white,
                                    glyph: .symbol("tram.fill"), glyphColor: .white),
        "tram_station_sign": .init(outline: .square, fill: blue, border: .white,
                                   glyph: .symbol("tram.fill"), glyphColor: .white),
        "train_station_sign": .init(outline: .square, fill: blue, border: .white,
                                    glyph: .symbol("train.side.front.car"), glyphColor: .white),
        "airport_sign": .init(outline: .square, fill: blue, border: .white,
                              glyph: .symbol("airplane"), glyphColor: .white),
        "bike_share_sign": .init(outline: .square, fill: blue, border: .white,
                                 glyph: .symbol("bicycle"), glyphColor: .white),
        "pedestrian_zone_sign": .init(outline: .square, fill: blue, border: .white,
                                      glyph: .symbol("figure.walk"), glyphColor: .white),
        "disabled_parking_sign": .init(outline: .square, fill: blue, border: .white,
                                       glyph: .symbol("figure.roll"), glyphColor: .white),
        "loading_zone_sign": .init(outline: .square, fill: blue, border: .white,
                                   glyph: .symbol("shippingbox.fill"), glyphColor: .white),

        // Parking — the P / E pair, and their crossed-out prohibitions
        "parking_sign": .init(outline: .square, fill: blue, border: .white,
                              glyph: .text("P"), glyphColor: .white),
        "estacionamiento_sign": .init(outline: .square, fill: blue, border: .white,
                                      glyph: .text("E"), glyphColor: .white),
        "no_parking_sign": .init(outline: .circle, fill: .white, border: red,
                                 glyph: .text("P"), glyphColor: .black, slashed: true),
        "no_estacionarse_sign": .init(outline: .circle, fill: .white, border: red,
                                      glyph: .text("E"), glyphColor: .black, slashed: true),
        "tow_away_sign": .init(outline: .rectangle, fill: .white, border: red,
                               glyph: .text("TOW"), glyphColor: red),

        // Routes
        "interstate_shield": .init(outline: .shield, fill: blue, border: red,
                                   glyph: .text("10"), glyphColor: .white),
        "us_route_shield": .init(outline: .shield, fill: .white, border: .black,
                                 glyph: .text("60"), glyphColor: .black),
        "state_route_shield": .init(outline: .rectangle, fill: .white, border: .black,
                                    glyph: .text("347"), glyphColor: .black),
        "business_route_shield": .init(outline: .rectangle, fill: green, border: .white,
                                       glyph: .text("BUS"), glyphColor: .white),
        "county_route_shield": .init(outline: .rectangle, fill: yellow, border: .black,
                                     glyph: .text("CR"), glyphColor: .black),
        "mex_federal_shield": .init(outline: .rectangle, fill: .white, border: .black,
                                    glyph: .text("15D"), glyphColor: .black),
        "mex_state_shield": .init(outline: .rectangle, fill: .white, border: .black,
                                  glyph: .text("MX"), glyphColor: .black),
        "toll_road_sign": .init(outline: .rectangle, fill: yellow, border: .black,
                                glyph: .text("TOLL"), glyphColor: .black),
        "cuota_sign": .init(outline: .rectangle, fill: yellow, border: .black,
                            glyph: .text("CUOTA"), glyphColor: .black),
        "libre_sign": .init(outline: .rectangle, fill: green, border: .white,
                            glyph: .text("LIBRE"), glyphColor: .white),
        "toll_booth_sign": .init(outline: .wideRectangle, fill: yellow, border: .black,
                                 glyph: .symbol("creditcard.fill"), glyphColor: .black),
        "express_lane_sign": .init(outline: .rectangle,
                                   fill: Color(red: 0.55, green: 0.27, blue: 0.68),
                                   border: .white, glyph: .text("HOV"), glyphColor: .white),
        "direction_banner": .init(outline: .wideRectangle, fill: green, border: .white,
                                  glyph: .text("WEST"), glyphColor: .white),

        // Guide
        "exit_panel": .init(outline: .wideRectangle, fill: green, border: .white,
                            glyph: .text("EXIT"), glyphColor: .white),
        "exit_number_tab": .init(outline: .wideRectangle, fill: green, border: .white,
                                 glyph: .text("164"), glyphColor: .white),
        "salida_panel": .init(outline: .wideRectangle, fill: green, border: .white,
                              glyph: .text("SAL"), glyphColor: .white),

        // Signals
        "signal_red": .init(outline: .circle, fill: Color(red: 0.9, green: 0.1, blue: 0.1),
                            border: .black, glyph: .none, glyphColor: .white),
        "signal_yellow": .init(outline: .circle, fill: yellow, border: .black,
                               glyph: .none, glyphColor: .black),
        "signal_green": .init(outline: .circle, fill: Color(red: 0.15, green: 0.75, blue: 0.35),
                              border: .black, glyph: .none, glyphColor: .white),
        "signal_arrow": .init(outline: .circle, fill: orange, border: .black,
                              glyph: .symbol("arrow.turn.up.left"), glyphColor: .black),

        // Advertising, so it's unmistakable in the list
        "billboard": .init(outline: .wideRectangle, fill: Color(white: 0.35), border: Color(white: 0.6),
                           glyph: .symbol("xmark"), glyphColor: .white),
        "business_sign": .init(outline: .wideRectangle, fill: Color(white: 0.35), border: Color(white: 0.6),
                               glyph: .symbol("xmark"), glyphColor: .white),
    ]

    // MARK: Whole families

    private static func byGroup(_ item: LabelClass) -> SignFace {
        let colour = Color(hex: item.color)
        switch item.group {
        case "Services", "Transit":
            return .init(outline: .square, fill: blue, border: .white,
                         glyph: .symbol("info"), glyphColor: .white)
        case "Landmarks":
            return .init(outline: .wideRectangle, fill: brown, border: .white,
                         glyph: .symbol("building.columns.fill"), glyphColor: .white)
        case "Guide":
            return .init(outline: .wideRectangle, fill: green, border: .white,
                         glyph: .symbol("signpost.right.fill"), glyphColor: .white)
        case "Routes":
            return .init(outline: .rectangle, fill: .white, border: .black,
                         glyph: .symbol("road.lanes"), glyphColor: .black)
        case "Lane & clearance":
            return .init(outline: .diamond, fill: yellow, border: .black,
                         glyph: .symbol("arrow.left.and.right"), glyphColor: .black)
        case "Signs":
            return .init(outline: .diamond, fill: yellow, border: .black,
                         glyph: .none, glyphColor: .black)
        case "Signals":
            return .init(outline: .circle, fill: colour, border: .black,
                         glyph: .none, glyphColor: .white)
        default:
            // Road users, obstacles, surface — no sign exists, so a plain
            // plaque in the class colour is the honest representation.
            return .init(outline: .rectangle, fill: colour, border: Color(white: 0.35),
                         glyph: .none, glyphColor: .white)
        }
    }
}

// MARK: - The view

/// One class drawn as its sign, at any size.
struct SignThumbnail: View {
    let item: LabelClass
    var size: CGFloat = 22

    var body: some View {
        let face = SignFace.face(for: item)
        ZStack {
            shape(face.outline)
                .fill(face.fill)
            shape(face.outline)
                .stroke(face.border, lineWidth: max(1, size * 0.07))
                .padding(size * 0.06)
            glyphView(face)
            if face.slashed {
                Capsule()
                    .fill(SignFace.red)
                    .frame(width: size * 0.78, height: max(2, size * 0.11))
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: size, height: size * heightRatio(face.outline))
        .accessibilityLabel(item.display)
    }

    @ViewBuilder
    private func glyphView(_ face: SignFace) -> some View {
        switch face.glyph {
        case .none:
            EmptyView()
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(face.glyphColor)
        case .text(let text):
            Text(text)
                .font(.system(size: size * 0.34, weight: .heavy))
                .foregroundStyle(face.glyphColor)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, size * 0.1)
        }
    }

    /// Type-erased so the same outline can be both filled and stroked — a
    /// `@ViewBuilder` here would hand back an opaque View with no `.fill`.
    private func shape(_ outline: SignFace.Outline) -> AnyShape {
        switch outline {
        case .octagon: return AnyShape(SignOctagon())
        case .invertedTriangle: return AnyShape(SignInvertedTriangle())
        case .diamond: return AnyShape(SignDiamond())
        case .pentagon: return AnyShape(SignPentagon())
        case .circle: return AnyShape(Circle())
        case .shield: return AnyShape(SignShield())
        case .rectangle, .square: return AnyShape(RoundedRectangle(cornerRadius: size * 0.12))
        case .wideRectangle: return AnyShape(RoundedRectangle(cornerRadius: size * 0.1))
        }
    }

    /// Guide panels are wider than tall; yield is slightly squat.
    private func heightRatio(_ outline: SignFace.Outline) -> CGFloat {
        switch outline {
        case .wideRectangle: return 0.62
        case .invertedTriangle: return 0.88
        default: return 1
        }
    }
}
