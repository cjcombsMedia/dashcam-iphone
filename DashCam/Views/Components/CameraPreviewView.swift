import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview backed by AVCaptureVideoPreviewLayer, kept in sync
/// with interface rotation. Taps are converted to device focus coordinates.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called with (devicePoint, layerPoint) when the user taps the preview.
    var onFocusTap: ((CGPoint, CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.focusTapHandler = onFocusTap
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.focusTapHandler = onFocusTap
        uiView.updateRotation()
    }

    final class PreviewHostView: UIView {
        var focusTapHandler: ((CGPoint, CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let handler = focusTapHandler else { return }
            let layerPoint = gesture.location(in: self)
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            handler(devicePoint, layerPoint)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        func updateRotation() {
            guard let connection = videoPreviewLayer.connection else { return }
            let orientation = window?.windowScene?.interfaceOrientation ?? .landscapeRight
            let angle: CGFloat
            switch orientation {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            default: angle = 0
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
}
