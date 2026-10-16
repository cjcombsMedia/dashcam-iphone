import SwiftUI
import UIKit

/// Mocked-up road signs and signal shown while driving, driven by RoadScene.
struct RoadSignsOverlay: View {
    @ObservedObject var scene: RoadScene
    /// Signal mock only shows when slowing/stopped; detection never pauses.
    var showSignal: Bool = true
    /// Long-pressing a remembered sign (the ones badged "M") asks to remove
    /// it. Only memory-sourced signs can be removed — a sign the camera is
    /// reading right now is on the pole in front of you.
    var onForget: ((RoadFeatureType) -> Void)?
    /// Set from Settings. When a posted clearance is at or below this, the
    /// sign turns red instead of green.
    var vehicleHeightInches: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let limit = scene.speedLimit {
                SpeedLimitSignView(limit: limit)
                    .rememberedSign(.speedLimit, scene: scene, onForget: onForget)
            }
            if scene.humpUntil != nil {
                SpeedHumpSignView(speed: scene.humpSpeed)
                    .rememberedSign(.hump, scene: scene, onForget: onForget)
            }
            if scene.schoolUntil != nil {
                SchoolCrossingSignView(speed: scene.schoolSpeed)
                    .rememberedSign(.school, scene: scene, onForget: onForget)
            }
            if scene.hospitalUntil != nil {
                HospitalSignView()
                    .rememberedSign(.hospital, scene: scene, onForget: onForget)
            }
            if scene.bikeUntil != nil {
                BikeLaneSignView()
                    .rememberedSign(.bike, scene: scene, onForget: onForget)
            }
            // Regulatory signs, drawn in their real MUTCD shapes.
            ForEach(RoadSignsOverlay.regulatoryOrder, id: \.self) { type in
                if scene.regulatorySigns[type] != nil {
                    regulatorySign(type)
                        .rememberedSign(type, scene: scene, onForget: onForget)
                }
            }
            // Freeway signage. Clearance leads — it's the only one that can
            // end a trip badly.
            if let clearance = scene.clearance {
                ClearanceSignView(clearance: clearance, vehicleHeightInches: vehicleHeightInches)
                    .rememberedSign(.lowClearance, scene: scene, onForget: onForget)
            }
            if scene.speedReducedAhead {
                SpeedReducedSignView()
            }
            if let merge = scene.mergeKind {
                MergeSignView(kind: merge)
            }
            if let route = scene.routeShield {
                RouteShieldView(shield: route.shield, number: route.number, direction: route.direction)
            }
            if let exit = scene.exitAhead {
                ExitSignView(info: exit)
            }
            if !scene.services.isEmpty {
                ServicesSignView(kinds: scene.services)
            }
            if let landmark = scene.landmarkName {
                LandmarkSignView(name: landmark)
            }
            if showSignal, let signal = scene.signal {
                TrafficSignalMockView(kind: signal)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scene.speedLimit)
        .animation(.easeInOut(duration: 0.2), value: scene.signal)
    }

    /// Most urgent first, so a stop sign never sits behind a crossing sign.
    static let regulatoryOrder: [RoadFeatureType] =
        [.stop, .doNotEnter, .yield, .railroad, .pedestrianCrossing]

    @ViewBuilder
    private func regulatorySign(_ type: RoadFeatureType) -> some View {
        switch type {
        case .stop: StopSignView()
        case .yield: YieldSignView()
        case .doNotEnter: DoNotEnterSignView()
        case .railroad: RailroadSignView()
        case .pedestrianCrossing: PedestrianCrossingSignView()
        default: EmptyView()
        }
    }
}

private extension View {
    /// Badges a sign that came from memory and makes it removable with a
    /// long press. A sign the camera is reading live gets neither — you
    /// can't delete something that's physically in front of you.
    func rememberedSign(
        _ type: RoadFeatureType,
        scene: RoadScene,
        onForget: ((RoadFeatureType) -> Void)?
    ) -> some View {
        let remembered = scene.memorySourcedTypes.contains(type)
        return self
            .memoryBadge(remembered)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.6) {
                guard remembered else { return }
                Haptics.warning()
                onForget?(type)
            }
            .accessibilityHint(remembered ? "Press and hold to remove this remembered sign" : "")
    }
}

/// Small "M" tag marking a sign that came from remembered geo data rather
/// than a live camera read — useful while detection is still being tuned.
private struct MemoryBadge: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if active {
                Text("M")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.cyan, in: Capsule())
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("From memory")
            }
        }
    }
}

extension View {
    func memoryBadge(_ active: Bool) -> some View {
        modifier(MemoryBadge(active: active))
    }
}

/// Full-width red alert bar for a fire station ahead — emergency vehicles
/// may pull out. Pulses gently rather than blinking harshly.
struct FireStationBanner: View {
    var label: String
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
            Text(label)
                .font(.system(size: 15, weight: .heavy))
            Text("— WATCH FOR EMERGENCY VEHICLES")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(red: 0.78, green: 0.05, blue: 0.05), in: RoundedRectangle(cornerRadius: 8))
        .opacity(pulsing ? 0.62 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityLabel("\(label) ahead — watch for emergency vehicles")
    }
}

/// Standard white regulatory speed sign. The number rolls with a numeric
/// flip when a new limit is detected.
struct SpeedLimitSignView: View {
    let limit: Int

    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED")
                .font(.system(size: 11, weight: .bold))
            Text("LIMIT")
                .font(.system(size: 11, weight: .bold))
            Text("\(limit)")
                .font(.system(size: 30, weight: .heavy))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(limit)))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black, lineWidth: 2).padding(2))
        .animation(.snappy(duration: 0.5), value: limit)
    }
}

/// Fluorescent yellow-green school crossing sign.
struct SchoolCrossingSignView: View {
    let speed: Int?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "figure.walk")
                .font(.system(size: 16, weight: .black))
            Text("SCHOOL")
                .font(.system(size: 11, weight: .heavy))
            if let speed {
                Text("\(speed) MPH")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(red: 0.81, green: 1.0, blue: 0.11), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black, lineWidth: 2).padding(2))
    }
}

/// Yellow warning sign that flashes for the hump window.
struct SpeedHumpSignView: View {
    let speed: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0
            VStack(spacing: 2) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 16, weight: .black))
                Text("BUMP")
                    .font(.system(size: 13, weight: .heavy))
                if let speed {
                    Text("\(speed) MPH")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.yellow, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black, lineWidth: 2).padding(2))
            .opacity(on ? 1.0 : 0.35)
            .shadow(color: .black.opacity(0.5), radius: 3)
        }
    }
}

/// Blue hospital sign; tapping routes to the nearest emergency room in Maps.
struct HospitalSignView: View {
    var body: some View {
        Button {
            DiagLog.shared.info("Road: hospital sign tapped — opening Maps")
            if let url = URL(string: "maps://?daddr=Emergency%20Room&dirflg=d") {
                UIApplication.shared.open(url)
            }
        } label: {
            Text("H")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color(red: 0, green: 0.28, blue: 0.73), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2).padding(2))
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hospital — tap for directions to the emergency entrance")
    }
}

/// Green bike-route sign.
struct BikeLaneSignView: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "bicycle")
                .font(.system(size: 18, weight: .bold))
            Text("BIKE ROUTE")
                .font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(red: 0, green: 0.45, blue: 0.23), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2).padding(2))
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// Vertical three-lamp signal mock with the detected color lit, or a
/// flashing yellow arrow.
struct TrafficSignalMockView: View {
    let kind: SignalDisplayKind

    var body: some View {
        Group {
            if kind == .flashingYellow {
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                    Image(systemName: "arrowshape.left.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.yellow)
                        .opacity(on ? 1 : 0.2)
                        .frame(width: 46, height: 62)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                VStack(spacing: 5) {
                    lamp(.red, lit: kind == .red)
                    lamp(.yellow, lit: kind == .yellow)
                    lamp(.green, lit: kind == .green)
                }
                .padding(6)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .accessibilityLabel("Traffic signal: \(label)")
    }

    private var label: String {
        switch kind {
        case .red: return "red"
        case .yellow: return "yellow"
        case .green: return "green"
        case .flashingYellow: return "flashing yellow arrow"
        }
    }

    private func lamp(_ color: Color, lit: Bool) -> some View {
        Circle()
            .fill(lit ? color : color.opacity(0.15))
            .frame(width: 16, height: 16)
            .shadow(color: lit ? color : .clear, radius: lit ? 5 : 0)
    }
}

/// Big green arrow pointing toward a detected cyclist.
struct CyclistWarningView: View {
    let direction: CyclistWarning.Direction

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 2 == 0
            VStack(spacing: 2) {
                Image(systemName: direction == .right ? "arrowshape.right.fill" : "arrowshape.left.fill")
                    .font(.system(size: 44, weight: .black))
                Text("PERSON")
                    .font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(.green)
            .opacity(on ? 1 : 0.45)
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 4)
        }
        .allowsHitTesting(false)
    }
}

/// Boxes around humans detected mid-frame (crosswalks), mapped through the
/// preview's aspect-fill crop. Landscape-only app → identity rotation.
struct PedestrianBoxesOverlay: View {
    let boxes: [CGRect]
    let videoDimensions: CGSize

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                let rect = mappedRect(box, in: geo.size)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.cyan, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func mappedRect(_ box: CGRect, in viewSize: CGSize) -> CGRect {
        guard videoDimensions.width > 0, videoDimensions.height > 0 else { return .zero }
        let scale = max(viewSize.width / videoDimensions.width, viewSize.height / videoDimensions.height)
        let drawnWidth = videoDimensions.width * scale
        let drawnHeight = videoDimensions.height * scale
        let offsetX = (viewSize.width - drawnWidth) / 2
        let offsetY = (viewSize.height - drawnHeight) / 2
        return CGRect(
            x: offsetX + box.minX * drawnWidth,
            y: offsetY + box.minY * drawnHeight,
            width: box.width * drawnWidth,
            height: box.height * drawnHeight
        )
    }
}
