import SwiftUI

/// Dimmed night-friendly HUD: black screen with large speed and heading.
/// Tap anywhere (handled by RecordingScreen) to return to the full preview.
///
/// Screensaver: the readout cluster, the TAG button, and the REC indicator
/// all glide Pong-style in one shared physics space — bouncing off the
/// screen edges AND off each other, so nothing overlaps and no pixels sit
/// still.
struct HUDView: View {
    @ObservedObject var location: LocationService
    var unit: SpeedUnit
    var night: Bool
    var fallbackHeading: Double?
    var showRecording: Bool
    var tagAction: () -> Void

    private var primaryColor: Color { night ? Color(red: 1.0, green: 0.45, blue: 0.15) : .white }
    private var secondaryColor: Color { night ? Color(red: 0.85, green: 0.35, blue: 0.1) : .gray }

    private var headingDegrees: Double {
        location.headingDegrees >= 0 ? location.headingDegrees : (fallbackHeading ?? -1)
    }

    // Physics state: 0 = readout cluster, 1 = TAG button, 2 = REC indicator.
    @State private var positions: [CGPoint?] = [nil, nil, nil]
    @State private var velocities: [CGVector] = [
        Self.randomVelocity(speed: 26),
        Self.randomVelocity(speed: 40),
        Self.randomVelocity(speed: 34),
    ]
    @State private var sizes: [CGSize] = [
        CGSize(width: 420, height: 300),
        CGSize(width: 190, height: 60),
        CGSize(width: 110, height: 44),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    cluster
                        .fixedSize()
                        .background(sizeReader(0))
                        .position(position(0, in: geo.size))
                    TagButton(night: night, action: tagAction)
                        .background(sizeReader(1))
                        .position(position(1, in: geo.size))
                    if showRecording {
                        PulsingRecordIndicator(night: night)
                            .background(sizeReader(2))
                            .position(position(2, in: geo.size))
                    }
                }
                .task(id: showRecording) {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 33_000_000)
                        guard !Task.isCancelled else { break }
                        step(in: geo.size)
                    }
                }
            }
        }
    }

    private var cluster: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                if night {
                    Image(systemName: "moon.fill")
                        .font(.title)
                        .foregroundStyle(secondaryColor)
                        .accessibilityLabel("Night processing active")
                }
                Text("\(Format.speedValue(metersPerSecond: location.speedMPS, unit: unit))")
                    .font(.system(size: 150, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(primaryColor)
                Text(unit.label)
                    .font(.title.bold())
                    .foregroundStyle(secondaryColor)
                    .padding(.top, 60)
            }
            Text(Format.heading(degrees: headingDegrees))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(secondaryColor)
            GPSFixIndicator(quality: location.fixQuality, night: night)
                .opacity(0.8)
        }
    }

    // MARK: - Physics

    private static func randomVelocity(speed: CGFloat) -> CGVector {
        let angle = Double.random(in: 0..<(2 * .pi))
        return CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
    }

    private func sizeReader(_ index: Int) -> some View {
        GeometryReader { inner in
            Color.clear
                .onAppear { sizes[index] = inner.size }
                .onChange(of: inner.size) { sizes[index] = inner.size }
        }
    }

    private func position(_ index: Int, in bounds: CGSize) -> CGPoint {
        positions[index] ?? defaultPosition(index, in: bounds)
    }

    private func defaultPosition(_ index: Int, in bounds: CGSize) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: bounds.width * 0.5, y: bounds.height * 0.45)
        case 1: return CGPoint(x: bounds.width * 0.3, y: bounds.height * 0.85)
        default: return CGPoint(x: bounds.width * 0.8, y: bounds.height * 0.8)
        }
    }

    private func step(in bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let dt: CGFloat = 0.033
        let active = showRecording ? [0, 1, 2] : [0, 1]

        // Integrate + wall bounce.
        for index in active {
            var point = positions[index] ?? defaultPosition(index, in: bounds)
            point.x += velocities[index].dx * dt
            point.y += velocities[index].dy * dt

            let halfWidth = min(sizes[index].width, bounds.width - 2) / 2
            let halfHeight = min(sizes[index].height, bounds.height - 2) / 2
            if point.x < halfWidth {
                point.x = halfWidth
                velocities[index].dx = abs(velocities[index].dx)
            } else if point.x > bounds.width - halfWidth {
                point.x = bounds.width - halfWidth
                velocities[index].dx = -abs(velocities[index].dx)
            }
            if point.y < halfHeight {
                point.y = halfHeight
                velocities[index].dy = abs(velocities[index].dy)
            } else if point.y > bounds.height - halfHeight {
                point.y = bounds.height - halfHeight
                velocities[index].dy = -abs(velocities[index].dy)
            }
            positions[index] = point
        }

        // Element-element collisions: separate along the shallow axis and
        // exchange that axis' velocity so they visibly bounce off each other.
        for i in active {
            for j in active where j > i {
                guard var pi = positions[i], var pj = positions[j] else { continue }
                let dx = pj.x - pi.x
                let dy = pj.y - pi.y
                let overlapX = (sizes[i].width + sizes[j].width) / 2 - abs(dx)
                let overlapY = (sizes[i].height + sizes[j].height) / 2 - abs(dy)
                guard overlapX > 0, overlapY > 0 else { continue }

                if overlapX < overlapY {
                    let direction: CGFloat = dx >= 0 ? 1 : -1
                    pi.x -= direction * overlapX / 2
                    pj.x += direction * overlapX / 2
                    let vi = velocities[i].dx
                    velocities[i].dx = -direction * abs(velocities[j].dx)
                    velocities[j].dx = direction * abs(vi)
                } else {
                    let direction: CGFloat = dy >= 0 ? 1 : -1
                    pi.y -= direction * overlapY / 2
                    pj.y += direction * overlapY / 2
                    let vi = velocities[i].dy
                    velocities[i].dy = -direction * abs(velocities[j].dy)
                    velocities[j].dy = direction * abs(vi)
                }
                positions[i] = pi
                positions[j] = pj
            }
        }
    }
}
