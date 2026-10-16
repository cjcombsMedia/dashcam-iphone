import SwiftUI

/// Brief yellow square shown where the user tapped to focus.
struct FocusSquare: View {
    @State private var appeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 2)
            .frame(width: 72, height: 72)
            .scaleEffect(appeared ? 1.0 : 1.4)
            .opacity(appeared ? 1 : 0.4)
            .animation(.easeOut(duration: 0.25), value: appeared)
            .onAppear { appeared = true }
    }
}

/// Manual camera controls: focus (infinity default / tap / manual lens
/// position) and exposure bias for brightness.
struct ManualCameraPanel: View {
    @ObservedObject var capture: CaptureService
    var close: () -> Void

    private var lensBinding: Binding<Float> {
        Binding(
            get: {
                if case .manual(let value) = capture.focusControl { return value }
                return 1.0
            },
            set: { capture.setLensPosition($0) }
        )
    }

    private var biasBinding: Binding<Float> {
        Binding(
            get: { capture.exposureBias },
            set: { capture.setExposureBias($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MANUAL CAMERA")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Focus — \(capture.focusStatusText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 10) {
                    Button {
                        capture.resetFocusToAuto()
                    } label: {
                        Text("AUTO")
                            .font(.caption.bold())
                            .frame(width: 52, height: 30)
                            .background(
                                capture.focusControl == .auto ? Color.yellow.opacity(0.85) : Color.white.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(capture.focusControl == .auto ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "camera.macro")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: lensBinding, in: 0...1)
                    Image(systemName: "mountain.2.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text("AUTO keeps the road in focus (far-range autofocus). Tap the preview to focus on a point, or drag the slider for a fixed manual focus.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "Brightness %+.1f EV", capture.exposureBias))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: biasBinding, in: -2...2, step: 0.1)
                    Image(systemName: "sun.max.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Button("0") {
                        capture.setExposureBias(0)
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
    }
}
