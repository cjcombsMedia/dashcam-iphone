import AVFoundation
import CoreImage
import Foundation
import UIKit

enum TelemetryBurnError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The clip has no video track."
        case .exportFailed(let message): return "Export failed: \(message)"
        }
    }
}

/// Renders telemetry (time, speed, heading, position) onto exported video.
///
/// Implementation: a CoreImage compositing handler that runs for every output
/// frame — the overlay for the frame's second is drawn over the source image
/// directly. Deterministic per-frame logic (no CoreAnimation timeline
/// semantics), so what you see in the handler is what lands in the file.
/// What an export includes.
enum ExportMode: String, CaseIterable, Identifiable {
    case videoOnly
    case basicOverlay
    case fullGraphical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .videoOnly: return "Video only"
        case .basicOverlay: return "Basic overlay"
        case .fullGraphical: return "Full graphical"
        }
    }

    var detail: String {
        switch self {
        case .videoOnly: return "Clean footage, fastest"
        case .basicOverlay: return "Telemetry text along the bottom"
        case .fullGraphical: return "Everything the live screen showed"
        }
    }
}

enum TelemetryBurner {
    static func burn(
        videoURL: URL,
        sidecar: TelemetrySidecar?,
        fallbackDate: Date,
        unit: SpeedUnit,
        mode: ExportMode = .basicOverlay
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TelemetryBurnError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let durationTime = try await asset.load(.duration)
        let duration = max(1, CMTimeGetSeconds(durationTime))

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))

        if let sidecar {
            DiagLog.shared.info("Burn: \(sidecar.samples.count) telemetry samples for \(videoURL.lastPathComponent)")
        } else {
            DiagLog.shared.error("Burn: NO telemetry sidecar for \(videoURL.lastPathComponent) — date-only overlay")
        }

        let overlay = OverlayTimeline(
            sidecar: sidecar,
            fallbackDate: fallbackDate,
            unit: unit,
            duration: duration,
            renderSize: renderSize,
            mode: mode
        )

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                let source = request.sourceImage
                if mode != .videoOnly, let strip = overlay.image(at: request.compositionTime.seconds) {
                    request.finish(with: strip.composited(over: source), context: nil)
                } else {
                    request.finish(with: source, context: nil)
                }
            }
        )

        // Share as H.264 in a plain .mp4 — plays everywhere.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(videoURL.deletingPathExtension().lastPathComponent)-telemetry.mp4"
        )
        try? FileManager.default.removeItem(at: outputURL)

        let preset = max(renderSize.width, renderSize.height) > 2200
            ? AVAssetExportPreset3840x2160
            : AVAssetExportPreset1920x1080
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw TelemetryBurnError.exportFailed("No export session for preset \(preset)")
        }
        export.videoComposition = composition

        if #available(iOS 18.0, *) {
            do {
                try await export.export(to: outputURL, as: .mp4)
            } catch {
                DiagLog.shared.error("Telemetry burn failed for \(videoURL.lastPathComponent): \(error.localizedDescription)")
                throw TelemetryBurnError.exportFailed(error.localizedDescription)
            }
        } else {
            export.outputURL = outputURL
            export.outputFileType = .mp4
            await export.export()
            guard export.status == .completed else {
                let message = export.error?.localizedDescription ?? "status \(export.status.rawValue)"
                DiagLog.shared.error("Telemetry burn failed for \(videoURL.lastPathComponent): \(message)")
                throw TelemetryBurnError.exportFailed(message)
            }
        }

        DiagLog.shared.info("Exported \(videoURL.lastPathComponent) with telemetry overlay")
        return outputURL
    }
}

/// Pre-computed per-second overlay text, rendered lazily to CIImage strips.
/// Export requests frames in order, so caching the current second's strip is
/// enough; access is locked because the handler can run on any queue.
/// `@unchecked Sendable`: all stored config is immutable and the mutable
/// cache is guarded by `lock`.
private final class OverlayTimeline: @unchecked Sendable {
    private let textBySecond: [String]
    private let renderSize: CGSize
    private let fontSize: CGFloat
    private let margin: CGFloat
    private let stripHeight: CGFloat
    private let mode: ExportMode
    /// Overlay state per second for full-graphical rendering.
    private let snapshotBySecond: [OverlaySnapshot?]

    private let lock = NSLock()
    private var cachedSecond = -1
    private var cachedImage: CIImage?

    init(
        sidecar: TelemetrySidecar?,
        fallbackDate: Date,
        unit: SpeedUnit,
        duration: Double,
        renderSize: CGSize,
        mode: ExportMode = .basicOverlay
    ) {
        self.renderSize = renderSize
        self.mode = mode
        fontSize = max(18, renderSize.height * 0.032)
        margin = fontSize * 0.5
        stripHeight = fontSize * 1.6

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let totalSeconds = max(1, Int(duration.rounded(.up)))
        let fallback = "\(formatter.string(from: fallbackDate))   Dash Cam"
        var texts = [String](repeating: fallback, count: totalSeconds)

        if let sidecar, !sidecar.samples.isEmpty {
            let samples = sidecar.samples
            for (index, sample) in samples.enumerated() {
                let start = sample.timestamp.timeIntervalSince(sidecar.startedAt)
                guard start < duration else { continue }
                let startIdx = max(0, Int(start))
                let endIdx = index + 1 < samples.count
                    ? min(totalSeconds, max(startIdx + 1, Int(samples[index + 1].timestamp.timeIntervalSince(sidecar.startedAt))))
                    : totalSeconds
                guard startIdx < totalSeconds else { continue }
                let text = Self.line(for: sample, unit: unit, formatter: formatter)
                for second in startIdx..<endIdx {
                    texts[second] = text
                }
            }
        }
        textBySecond = texts

        // Bucket overlay snapshots by second for full-graphical export.
        var snapshots = [OverlaySnapshot?](repeating: nil, count: totalSeconds)
        for snapshot in sidecar?.overlaySnapshots ?? [] {
            let index = min(max(0, Int(snapshot.offset)), totalSeconds - 1)
            snapshots[index] = snapshot
        }
        // Carry a snapshot forward through seconds that have none.
        var carried: OverlaySnapshot?
        for index in 0..<snapshots.count {
            if let current = snapshots[index] {
                carried = current
            } else {
                snapshots[index] = carried
            }
        }
        snapshotBySecond = snapshots
    }

    func image(at time: Double) -> CIImage? {
        let second = min(max(0, Int(time)), textBySecond.count - 1)
        lock.lock()
        defer { lock.unlock() }
        if second == cachedSecond {
            return cachedImage
        }
        let image = mode == .fullGraphical
            ? renderFull(text: textBySecond[second], snapshot: snapshotBySecond[second])
            : renderStrip(text: textBySecond[second])
        cachedSecond = second
        cachedImage = image
        return image
    }

    private static func line(for sample: TelemetrySample, unit: SpeedUnit, formatter: DateFormatter) -> String {
        let time = formatter.string(from: sample.timestamp)
        let speed = sample.speedMPS.map {
            "\(Format.speedValue(metersPerSecond: $0, unit: unit)) \(unit.label)"
        } ?? "-- \(unit.label)"
        let heading = sample.headingDegrees.map { Format.heading(degrees: $0) } ?? "--"
        let position = Format.coordinate(latitude: sample.latitude, longitude: sample.longitude)
        var line = "\(time)   \(speed)   \(heading)   \(position)"
        if let vibration = Format.vibration(g: sample.vibrationG) {
            line += "   \(vibration)"
        }
        if let thermal = Format.thermal(raw: sample.thermal) {
            line += "   \(thermal)"
        }
        return line
    }

    private func renderStrip(text: String) -> CIImage? {
        let width = renderSize.width - 2 * margin
        guard width > 10 else { return nil }
        let size = CGSize(width: width, height: stripHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let image = renderer.image { context in
            let backgroundWidth = min(width, textSize.width + fontSize)
            let background = UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: backgroundWidth, height: stripHeight),
                cornerRadius: fontSize * 0.3
            )
            UIColor.black.withAlphaComponent(0.4).setFill()
            background.fill()
            (text as NSString).draw(
                at: CGPoint(x: fontSize * 0.5, y: (stripHeight - textSize.height) / 2),
                withAttributes: attributes
            )
        }

        guard let cgImage = image.cgImage else { return nil }
        // CoreImage works in bottom-left coordinates; place near the bottom.
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
    }

    /// Full-graphical: the telemetry strip plus the mock signs, signal, and
    /// detection boxes exactly as the live screen showed them.
    private func renderFull(text: String, snapshot: OverlaySnapshot?) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 3

        let image = renderer.image { context in
            let cg = context.cgContext

            // Bottom telemetry strip.
            let stripAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .shadow: shadow,
            ]
            let textSize = (text as NSString).size(withAttributes: stripAttributes)
            let stripRect = CGRect(
                x: margin,
                y: renderSize.height - stripHeight - margin,
                width: min(renderSize.width - 2 * margin, textSize.width + fontSize),
                height: stripHeight
            )
            UIColor.black.withAlphaComponent(0.4).setFill()
            UIBezierPath(roundedRect: stripRect, cornerRadius: fontSize * 0.3).fill()
            (text as NSString).draw(
                at: CGPoint(x: stripRect.minX + fontSize * 0.5,
                            y: stripRect.midY - textSize.height / 2),
                withAttributes: stripAttributes
            )

            guard let snapshot else { return }

            // Sign chips along the top-left, mirroring the live layout.
            var x = margin
            let chipY = margin
            let chipHeight = fontSize * 3.2

            func drawChip(lines: [String], background: UIColor, textColor: UIColor, border: UIColor) {
                let font = UIFont.systemFont(ofSize: fontSize * 0.8, weight: .heavy)
                let width = max(
                    fontSize * 3.4,
                    (lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + fontSize
                )
                let rect = CGRect(x: x, y: chipY, width: width, height: chipHeight)
                background.setFill()
                let path = UIBezierPath(roundedRect: rect, cornerRadius: fontSize * 0.4)
                path.fill()
                border.setStroke()
                path.lineWidth = 2
                path.stroke()

                var lineY = rect.minY + fontSize * 0.35
                for line in lines {
                    let size = (line as NSString).size(withAttributes: [.font: font])
                    (line as NSString).draw(
                        at: CGPoint(x: rect.midX - size.width / 2, y: lineY),
                        withAttributes: [.font: font, .foregroundColor: textColor]
                    )
                    lineY += size.height + 1
                }
                x += width + fontSize * 0.4
            }

            if let limit = snapshot.speedLimit {
                drawChip(lines: ["SPEED", "LIMIT", "\(limit)"], background: .white, textColor: .black, border: .black)
            }
            if snapshot.humpShowing {
                var lines = ["BUMP"]
                if let speed = snapshot.humpSpeed { lines.append("\(speed) MPH") }
                drawChip(lines: lines, background: .systemYellow, textColor: .black, border: .black)
            }
            if snapshot.schoolShowing {
                var lines = ["SCHOOL"]
                if let speed = snapshot.schoolSpeed { lines.append("\(speed) MPH") }
                drawChip(
                    lines: lines,
                    background: UIColor(red: 0.81, green: 1, blue: 0.11, alpha: 1),
                    textColor: .black, border: .black
                )
            }
            if snapshot.hospitalShowing {
                drawChip(
                    lines: ["H"],
                    background: UIColor(red: 0, green: 0.28, blue: 0.73, alpha: 1),
                    textColor: .white, border: .white
                )
            }
            if snapshot.bikeShowing {
                drawChip(
                    lines: ["BIKE", "ROUTE"],
                    background: UIColor(red: 0, green: 0.45, blue: 0.23, alpha: 1),
                    textColor: .white, border: .white
                )
            }
            if let fireStation = snapshot.fireStation {
                drawChip(
                    lines: fireStation.components(separatedBy: " "),
                    background: UIColor(red: 0.78, green: 0.05, blue: 0.05, alpha: 1),
                    textColor: .white, border: .white
                )
            }
            if let city = snapshot.cityName {
                drawChip(
                    lines: ["WELCOME", city.uppercased()],
                    background: UIColor(red: 0, green: 0.45, blue: 0.23, alpha: 1),
                    textColor: .white, border: .white
                )
            }

            // Traffic signal mock.
            if let signal = snapshot.signal, signal != "none" {
                let lampRadius = fontSize * 0.45
                let bodyWidth = lampRadius * 3
                let bodyHeight = lampRadius * 8
                let bodyRect = CGRect(x: x, y: chipY, width: bodyWidth, height: bodyHeight)
                UIColor.black.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: bodyRect, cornerRadius: lampRadius * 0.8).fill()

                let colors: [(String, UIColor)] = [
                    ("red", .systemRed), ("yellow", .systemYellow), ("green", .systemGreen),
                ]
                for (index, entry) in colors.enumerated() {
                    let lit = signal == entry.0
                        || (signal == "flashingYellow" && entry.0 == "yellow")
                    let center = CGPoint(
                        x: bodyRect.midX,
                        y: bodyRect.minY + lampRadius * 1.6 + CGFloat(index) * lampRadius * 2.4
                    )
                    (lit ? entry.1 : entry.1.withAlphaComponent(0.15)).setFill()
                    UIBezierPath(
                        ovalIn: CGRect(
                            x: center.x - lampRadius, y: center.y - lampRadius,
                            width: lampRadius * 2, height: lampRadius * 2
                        )
                    ).fill()
                }
            }

            // Pedestrian boxes.
            if let boxes = snapshot.pedestrians {
                UIColor.cyan.setStroke()
                for box in boxes where box.count == 4 {
                    let rect = CGRect(
                        x: box[0] * renderSize.width, y: box[1] * renderSize.height,
                        width: box[2] * renderSize.width, height: box[3] * renderSize.height
                    )
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
                    path.lineWidth = 3
                    path.stroke()
                }
            }

            // Cyclist warning arrow.
            if let side = snapshot.cyclist {
                let arrowFont = UIFont.systemFont(ofSize: fontSize * 2, weight: .heavy)
                let label = side == "right" ? "CYCLIST ▶" : "◀ CYCLIST"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: arrowFont,
                    .foregroundColor: UIColor.systemGreen,
                    .shadow: shadow,
                ]
                let size = (label as NSString).size(withAttributes: attributes)
                let point = CGPoint(
                    x: side == "right" ? renderSize.width - size.width - margin * 2 : margin * 2,
                    y: renderSize.height / 2 - size.height / 2
                )
                (label as NSString).draw(at: point, withAttributes: attributes)
            }

            _ = cg
        }

        guard let cgImage = image.cgImage else { return nil }
        // Rendered in top-left coordinates; flip for CoreImage.
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: renderSize.height))
    }
}
