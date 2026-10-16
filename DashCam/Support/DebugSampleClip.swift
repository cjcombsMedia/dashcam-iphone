import AVFoundation
import CoreVideo
import SwiftData
import UIKit

/// Debug-only helper that renders a short synthetic clip (plus telemetry
/// sidecar) into the LOOP folder so the library, player, tagging, and
/// storage logic can be exercised in the Simulator, which has no camera.
@MainActor
enum DebugSampleClip {
    static func generate(
        storage: StorageManager,
        tagStore: TagStore,
        context: ModelContext,
        tagged: Bool
    ) async {
        try? storage.ensureFolders()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "SAMPLE_\(formatter.string(from: Date()))_\(Int.random(in: 100...999)).mov"
        let url = storage.url(forFileName: fileName, in: .loop)
        let startedAt = Date()

        let ok = await Task.detached(priority: .userInitiated) {
            Self.writeVideo(to: url)
        }.value
        guard ok else { return }

        // 1 Hz sidecar with plausible driving values.
        let samples = (0..<4).map { second in
            TelemetrySample(
                timestamp: startedAt.addingTimeInterval(Double(second)),
                latitude: 37.7749 + Double(second) * 0.0001,
                longitude: -122.4194 + Double(second) * 0.0001,
                altitude: 16,
                speedMPS: 13.4 + Double(second),
                headingDegrees: 245
            )
        }
        let sidecar = TelemetrySidecar(
            segmentFileName: fileName,
            resolution: VideoResolution.hd.rawValue,
            startedAt: startedAt,
            samples: samples
        )
        let sidecarFileName = (fileName as NSString).deletingPathExtension + ".json"
        let sidecarURL = storage.url(forFileName: sidecarFileName, in: .loop)
        try? TelemetrySidecar.encoder().encode(sidecar).write(to: sidecarURL, options: .atomic)

        let size = storage.fileSize(fileName: fileName, in: .loop)
        let result = CaptureService.SegmentResult(
            url: url,
            fileName: fileName,
            startedAt: startedAt,
            duration: 3,
            resolution: .hd,
            fileSize: size,
            isFinal: true
        )
        let tags: [PendingTag] = tagged
            ? [PendingTag(
                timestamp: startedAt.addingTimeInterval(1.5),
                offsetInClip: 1.5,
                latitude: 37.7749,
                longitude: -122.4194,
                speedMPS: 15,
                source: .manual
            )]
            : []
        let clip = tagStore.registerSegment(
            result: result,
            sidecarFileName: sidecarFileName,
            pendingTags: tags,
            context: context
        )
        // Sample clips are written flat, not fragmented.
        clip.isOptimized = true
        try? context.save()
    }

    /// Renders 90 frames (3 s @ 30 fps) of shifting color, H.264 720p so it
    /// encodes in the Simulator.
    nonisolated private static func writeVideo(to url: URL) -> Bool {
        let width = 1280
        let height = 720
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            for frame in 0..<90 {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard let pool = adaptor.pixelBufferPool else { return false }
                var bufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
                guard let buffer = bufferOut else { return false }

                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                    let hue = Double(frame) / 90.0
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    UIColor(hue: hue, saturation: 0.7, brightness: 0.7, alpha: 1)
                        .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    let pixel: [UInt8] = [UInt8(blue * 255), UInt8(green * 255), UInt8(red * 255), 255]
                    for row in 0..<height {
                        let rowStart = base.advanced(by: row * bytesPerRow)
                        var offset = 0
                        for _ in 0..<width {
                            rowStart.advanced(by: offset).copyMemory(from: pixel, byteCount: 4)
                            offset += 4
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])

                let time = CMTime(value: CMTimeValue(frame), timescale: 30)
                adaptor.append(buffer, withPresentationTime: time)
            }

            input.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()
            return writer.status == .completed
        } catch {
            return false
        }
    }
}
