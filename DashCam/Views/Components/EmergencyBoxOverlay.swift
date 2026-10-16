import SwiftUI
import UIKit

/// Green detection box drawn over the camera preview where flashing
/// emergency lights were spotted. The detection rect arrives normalized in
/// (landscape) buffer coordinates; this view rotates it to match the
/// interface orientation and maps it through the preview's aspect-fill crop.
struct EmergencyBoxOverlay: View {
    let detection: EmergencyDetection
    /// Buffer dimensions of the active format (landscape, e.g. 1920x1080).
    let videoDimensions: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = mappedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Text("EMERGENCY LIGHTS")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
                    .offset(x: rect.minX, y: max(0, rect.minY - 20))
            }
            .animation(.easeInOut(duration: 0.15), value: detection.box)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityLabel("Emergency lights detected")
    }

    private func mappedRect(in viewSize: CGSize) -> CGRect {
        let box = detection.box
        let angle = Self.previewRotationAngle()

        // Rotate the normalized buffer rect into display orientation.
        var rotated: CGRect
        var videoSize = videoDimensions
        switch angle {
        case 90:
            rotated = CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
            videoSize = CGSize(width: videoDimensions.height, height: videoDimensions.width)
        case 180:
            rotated = CGRect(x: 1 - box.maxX, y: 1 - box.maxY, width: box.width, height: box.height)
        case 270:
            rotated = CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
            videoSize = CGSize(width: videoDimensions.height, height: videoDimensions.width)
        default:
            rotated = box
        }

        // Aspect-fill mapping (matches the preview layer's resizeAspectFill).
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let drawnWidth = videoSize.width * scale
        let drawnHeight = videoSize.height * scale
        let offsetX = (viewSize.width - drawnWidth) / 2
        let offsetY = (viewSize.height - drawnHeight) / 2

        return CGRect(
            x: offsetX + rotated.minX * drawnWidth,
            y: offsetY + rotated.minY * drawnHeight,
            width: rotated.width * drawnWidth,
            height: rotated.height * drawnHeight
        )
    }

    /// Same angle the preview layer uses for the current interface orientation.
    private static func previewRotationAngle() -> Int {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .landscapeRight
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        default: return 0
        }
    }
}
