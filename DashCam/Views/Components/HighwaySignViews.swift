import SwiftUI

/// Freeway signage drawn the way it appears on the road: green for guidance,
/// blue for services, brown for landmarks, yellow for warnings, and the
/// route shield the number actually sits on.
///
/// Colour is the first thing a driver decodes at 75 mph — brown means
/// "somewhere to visit", blue means "fuel and food", green means "where this
/// road goes". Rendering them all in one house style would throw that away.

/// EXIT 164 tab over a green destination panel.
struct ExitSignView: View {
    let info: ExitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let number = info.number {
                Text("EXIT \(number)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(USSignColor.green, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.white, lineWidth: 1).padding(1)
                    )
                    .offset(x: 6)
                    .zIndex(1)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let destination = info.destination {
                    Text(destination)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                if let miles = info.milesAway {
                    Text(milesText(miles))
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 190, alignment: .leading)
            .background(USSignColor.green, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white, lineWidth: 1.5).padding(2)
            )
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel(accessibilityText)
    }

    private func milesText(_ miles: Double) -> String {
        if miles < 1 { return String(format: "%.2f MILES", miles) }
        let whole = Int(miles)
        let fraction = miles - Double(whole)
        if fraction > 0.4 && fraction < 0.6 { return "\(whole)½ MILES" }
        if fraction > 0.2 && fraction < 0.3 { return "\(whole)¼ MILES" }
        return whole == 1 ? "1 MILE" : "\(whole) MILES"
    }

    private var accessibilityText: String {
        [info.number.map { "Exit \($0)" }, info.destination,
         info.milesAway.map { milesText($0) }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Interstate, US, state or Mexican federal route shield with a direction.
struct RouteShieldView: View {
    let shield: RouteShield
    let number: String
    let direction: String?

    var body: some View {
        VStack(spacing: 2) {
            if let direction {
                Text(direction.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(USSignColor.green, in: RoundedRectangle(cornerRadius: 3))
            }
            shieldBody
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("\(direction ?? "") \(shield.label) \(number)")
    }

    @ViewBuilder
    private var shieldBody: some View {
        switch shield {
        case .interstate:
            ZStack {
                InterstateShieldShape().fill(USSignColor.red)
                InterstateShieldShape().fill(USSignColor.blue).padding(3)
                VStack(spacing: -2) {
                    Text("INTERSTATE")
                        .font(.system(size: 5, weight: .heavy))
                        .opacity(0.9)
                    Text(number)
                        .font(.system(size: 20, weight: .heavy))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
            }
            .frame(width: 46, height: 44)
        case .usHighway, .state:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.white)
                RoundedRectangle(cornerRadius: 6).strokeBorder(.black, lineWidth: 2).padding(2)
                Text(number)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
            }
            .frame(width: 44, height: 42)
        case .mexicoFederal:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.white)
                RoundedRectangle(cornerRadius: 4).strokeBorder(.black, lineWidth: 2).padding(2)
                VStack(spacing: -1) {
                    Text("MEX").font(.system(size: 7, weight: .heavy))
                    Text(number)
                        .font(.system(size: 17, weight: .heavy))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
            }
            .frame(width: 44, height: 42)
        }
    }
}

/// The interstate shield outline: flat top, flared shoulders, pointed base.
struct InterstateShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.94, y: h * 0.10))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.5, y: h),
            control: CGPoint(x: w * 0.80, y: h * 0.82)
        )
        path.addQuadCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.42),
            control: CGPoint(x: w * 0.20, y: h * 0.82)
        )
        path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.10))
        path.closeSubpath()
        return path
    }
}

/// Overhead clearance. Turns red when it's lower than the vehicle height set
/// in Settings — the one case where this app should shout.
struct ClearanceSignView: View {
    let clearance: Clearance
    var vehicleHeightInches: Int?

    private var isTooLow: Bool {
        guard let vehicleHeightInches else { return false }
        return clearance.totalInches <= vehicleHeightInches
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isTooLow ? "exclamationmark.triangle.fill" : "arrow.up.and.down")
                .font(.system(size: 14, weight: .black))
            Text(clearance.label)
                .font(.system(size: 19, weight: .heavy))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isTooLow ? USSignColor.red : USSignColor.green, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5).padding(2))
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel(isTooLow
                            ? "Low clearance warning, \(clearance.label)"
                            : "Clearance \(clearance.label)")
    }
}

/// The big blue services panel: fuel, food, lodging at the next exit.
struct ServicesSignView: View {
    let kinds: Set<ServiceKind>

    /// Urban services get their own square signs; only the highway ones are
    /// grouped onto a single blue strip the way they appear on the road.
    private static let urban: Set<ServiceKind> = [.busStop, .taxi, .metro, .parking, .noParking]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ServiceKind.allCases.filter { kinds.contains($0) && Self.urban.contains($0) },
                    id: \.self) { kind in
                switch kind {
                case .parking: ParkingSignView(letter: "P")
                case .noParking: ParkingSignView(letter: "P", prohibited: true)
                default: TransitSignView(kind: kind)
                }
            }
            highwayStrip
        }
    }

    @ViewBuilder
    private var highwayStrip: some View {
        let highway = ServiceKind.allCases.filter { kinds.contains($0) && !Self.urban.contains($0) }
        if !highway.isEmpty {
            HStack(spacing: 8) {
                ForEach(highway, id: \.self) { kind in
                    VStack(spacing: 2) {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 15, weight: .bold))
                        Text(kind.label)
                            .font(.system(size: 7, weight: .heavy))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(USSignColor.blue, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5).padding(2))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .accessibilityLabel("Services ahead: " + highway.map(\.label).joined(separator: ", "))
        }
    }
}

/// Brown recreational and cultural guide sign.
struct LandmarkSignView: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 13, weight: .bold))
            Text(name)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 175, alignment: .leading)
        .background(USSignColor.brown, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5).padding(2))
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Landmark: \(name)")
    }
}

/// Yellow diamond lane-change warning.
struct MergeSignView: View {
    let kind: MergeKind

    var body: some View {
        ZStack {
            DiamondShape().fill(USSignColor.yellow)
            DiamondShape().stroke(.black, lineWidth: 2).padding(4)
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .black))
                Text(kind.label)
                    .font(.system(size: 7, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.black)
            .frame(width: 38)
        }
        .frame(width: 56, height: 56)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel(kind.label)
    }

    private var symbol: String {
        switch kind {
        case .merge: return "arrow.triangle.merge"
        case .addedLane: return "arrow.triangle.branch"
        case .laneEnds: return "arrow.merge"
        }
    }
}

/// "SPEED REDUCED AHEAD" — a warning, not a limit, so it stays a diamond.
struct SpeedReducedSignView: View {
    var body: some View {
        ZStack {
            DiamondShape().fill(USSignColor.yellow)
            DiamondShape().stroke(.black, lineWidth: 2).padding(4)
            VStack(spacing: -1) {
                Text("SPEED").font(.system(size: 9, weight: .heavy))
                Text("REDUCED").font(.system(size: 9, weight: .heavy))
                Text("AHEAD").font(.system(size: 9, weight: .heavy))
            }
            .foregroundStyle(.black)
            .minimumScaleFactor(0.7)
        }
        .frame(width: 58, height: 58)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Speed reduced ahead")
    }
}

/// Mexican and US urban service signs: a blue square with a white pictogram.
///
/// This is the shape of most city signage in Mexico — bus stop, metro, taxi,
/// parking — and it carries no text at all, which is why the camera can't
/// read one yet. Drawing it here means a remembered or manually tagged stop
/// still shows on the glass.
struct TransitSignView: View {
    let kind: ServiceKind
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.1)
                .fill(kind == .metro ? USSignColor.orange : USSignColor.blue)
            RoundedRectangle(cornerRadius: size * 0.1)
                .strokeBorder(.white, lineWidth: size * 0.055)
                .padding(size * 0.07)
            Image(systemName: kind.systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel(kind.label)
    }
}

/// Parking and its prohibition — "P" in the US, "E" in Mexico, and the
/// crossed-out version that means the opposite.
struct ParkingSignView: View {
    /// "P" or "E".
    let letter: String
    var prohibited: Bool = false
    var size: CGFloat = 50

    var body: some View {
        ZStack {
            if prohibited {
                Circle().fill(.white)
                Circle().strokeBorder(USSignColor.red, lineWidth: size * 0.11)
            } else {
                RoundedRectangle(cornerRadius: size * 0.1).fill(USSignColor.blue)
                RoundedRectangle(cornerRadius: size * 0.1)
                    .strokeBorder(.white, lineWidth: size * 0.055)
                    .padding(size * 0.07)
            }
            Text(letter)
                .font(.system(size: size * 0.5, weight: .heavy))
                .foregroundStyle(prohibited ? .black : .white)
            if prohibited {
                Capsule()
                    .fill(USSignColor.red)
                    .frame(width: size * 0.78, height: size * 0.11)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel(prohibited ? "No parking" : "Parking")
    }
}
