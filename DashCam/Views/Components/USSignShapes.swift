import SwiftUI

/// US road signs drawn to their real MUTCD shapes and colours, so what the
/// app shows on the glass matches what's on the pole.
///
/// Shape carries meaning on American roads — an octagon means stop even when
/// the legend is unreadable, an inverted triangle means yield, a yellow
/// diamond warns, a white rectangle regulates. Drawing everything as a
/// rounded rectangle throws that away, so each sign gets its true outline.
enum USSignColor {
    /// MUTCD red (Pantone 187).
    static let red = Color(red: 0.78, green: 0.06, blue: 0.18)
    /// MUTCD yellow.
    static let yellow = Color(red: 1.0, green: 0.79, blue: 0.0)
    /// Fluorescent yellow-green, used only for school and pedestrian signs.
    static let fluorescent = Color(red: 0.81, green: 1.0, blue: 0.11)
    /// MUTCD guide green.
    static let green = Color(red: 0.0, green: 0.42, blue: 0.28)
    /// MUTCD service blue.
    static let blue = Color(red: 0.0, green: 0.29, blue: 0.53)
    static let orange = Color(red: 0.96, green: 0.42, blue: 0.0)
    /// MUTCD brown — recreational and cultural guidance.
    static let brown = Color(red: 0.38, green: 0.24, blue: 0.13)
}

// MARK: - Outlines

/// Regular octagon — STOP, and nothing else. The shape is reserved.
struct OctagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side / 2
        var path = Path()
        for index in 0..<8 {
            // Rotated so flats sit top and bottom, as a real sign hangs.
            let angle = Double(index) * .pi / 4 + .pi / 8
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

/// Downward-pointing equilateral triangle — YIELD.
struct InvertedTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Square stood on a corner — the warning diamond.
struct DiamondShape: Shape {
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

/// Five-sided school-zone sign, point up.
struct SchoolPentagonShape: Shape {
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

// MARK: - Signs

/// R1-1 STOP: red octagon, white legend and border.
struct StopSignView: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            OctagonShape().fill(USSignColor.red)
            OctagonShape()
                .stroke(.white, lineWidth: size * 0.055)
                .padding(size * 0.07)
            Text("STOP")
                .font(.system(size: size * 0.28, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Stop sign ahead")
    }
}

/// R1-2 YIELD: white inverted triangle with a wide red border.
struct YieldSignView: View {
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            InvertedTriangleShape().fill(USSignColor.red)
            InvertedTriangleShape()
                .fill(.white)
                .padding(size * 0.16)
            Text("YIELD")
                .font(.system(size: size * 0.17, weight: .heavy))
                .foregroundStyle(USSignColor.red)
                .offset(y: -size * 0.13)
        }
        .frame(width: size, height: size * 0.87)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Yield ahead")
    }
}

/// R5-1 DO NOT ENTER: red disc with a white horizontal bar.
struct DoNotEnterSignView: View {
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            Circle().fill(USSignColor.red)
            Circle().stroke(.white, lineWidth: size * 0.05).padding(size * 0.06)
            Capsule()
                .fill(.white)
                .frame(width: size * 0.62, height: size * 0.17)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Do not enter")
    }
}

/// W10-1 railroad advance warning: yellow disc with a black crossbuck X.
struct RailroadSignView: View {
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            Circle().fill(USSignColor.yellow)
            Circle().stroke(.black, lineWidth: size * 0.045).padding(size * 0.05)
            Path { path in
                path.move(to: CGPoint(x: size * 0.22, y: size * 0.22))
                path.addLine(to: CGPoint(x: size * 0.78, y: size * 0.78))
                path.move(to: CGPoint(x: size * 0.78, y: size * 0.22))
                path.addLine(to: CGPoint(x: size * 0.22, y: size * 0.78))
            }
            .stroke(.black, lineWidth: size * 0.07)
            HStack(spacing: size * 0.30) {
                Text("R").font(.system(size: size * 0.2, weight: .heavy))
                Text("R").font(.system(size: size * 0.2, weight: .heavy))
            }
            .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Railroad crossing ahead")
    }
}

/// W11-2 pedestrian crossing: fluorescent yellow-green diamond.
struct PedestrianCrossingSignView: View {
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            DiamondShape().fill(USSignColor.fluorescent)
            DiamondShape().stroke(.black, lineWidth: size * 0.04).padding(size * 0.07)
            Image(systemName: "figure.walk")
                .font(.system(size: size * 0.36, weight: .black))
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Pedestrian crossing ahead")
    }
}

/// A generic yellow warning diamond, for hazards without a dedicated sign.
struct WarningDiamondSignView: View {
    let systemImage: String
    var caption: String?
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            DiamondShape().fill(USSignColor.yellow)
            DiamondShape().stroke(.black, lineWidth: size * 0.04).padding(size * 0.07)
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.3, weight: .black))
                if let caption {
                    Text(caption)
                        .font(.system(size: size * 0.15, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.black)
            .frame(width: size * 0.62)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
}
