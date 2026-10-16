import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import Vision

/// What the detector saw in one still frame — the ground truth for Training
/// Mode, so failures are explainable ("OCR read nothing" vs "read the text
/// but the parser rejected it" vs "blob failed the shape gate").
struct DetectionReport {
    var ocrLines: [String] = []
    var signs: [RoadSign] = []
    var signalRed = false
    var signalYellow = false
    var signalGreen = false
    var signalRegions: [CGRect] = []
    var schoolBlob = false
    var hospitalBlob = false
    var bikeBlob = false
    var humanBoxes: [CGRect] = []
    var notes: [String] = []
}

/// Runs the same detection logic as the live pipeline against an arbitrary
/// image, for Training Mode.
enum DetectionDiagnostics {
    static func analyze(image: UIImage) -> DetectionReport {
        var report = DetectionReport()
        guard let cgImage = image.cgImage else {
            report.notes.append("Could not read image data.")
            return report
        }

        // --- Vision: full frame + all zoom crops (Training Mode can afford
        // every crop; the live path rotates them for speed).
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        var requests: [VNRecognizeTextRequest] = []

        let full = VNRecognizeTextRequest()
        full.recognitionLevel = .accurate
        full.usesLanguageCorrection = false
        full.minimumTextHeight = 0.012
        requests.append(full)

        for region in RoadSceneAnalyzer.diagnosticCropRegions {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.02
            request.regionOfInterest = region
            requests.append(request)
        }

        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false

        try? handler.perform(requests + [humanRequest])

        var lines: [String] = []
        for request in requests {
            lines.append(contentsOf: (request.results ?? []).compactMap {
                $0.topCandidates(1).first?.string
            })
        }
        // De-duplicate while preserving order.
        var seen = Set<String>()
        report.ocrLines = lines.filter { seen.insert($0).inserted }
        report.signs = RoadTextParser.parse(report.ocrLines)

        var humans: [CGRect] = (humanRequest.results ?? []).map { result in
            let bb = result.boundingBox
            return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        }

        // Same digital-telephoto pass the live detector uses — distant
        // cyclists and walkers are far too small in a full wide frame.
        if let buffer = PixelBufferFactory.makeYUV420(from: cgImage) {
            for region in RoadSceneAnalyzer.diagnosticHumanCropRegions {
                guard let cropBuffer = CropRenderer.shared.crop(buffer, to: region) else { continue }
                let cropRequest = VNDetectHumanRectanglesRequest()
                cropRequest.upperBodyOnly = false
                let cropHandler = VNImageRequestHandler(cvPixelBuffer: cropBuffer, orientation: .up)
                try? cropHandler.perform([cropRequest])
                for result in cropRequest.results ?? [] {
                    let bb = result.boundingBox
                    humans.append(CGRect(
                        x: region.minX + bb.minX * region.width,
                        y: region.minY + (1 - bb.maxY) * region.height,
                        width: bb.width * region.width,
                        height: bb.height * region.height
                    ))
                }
            }
        }

        var mergedHumans: [CGRect] = []
        for person in humans where person.height >= 0.035 {
            if mergedHumans.contains(where: { $0.intersects(person.insetBy(dx: -0.01, dy: -0.01)) }) { continue }
            mergedHumans.append(person)
        }
        report.humanBoxes = mergedHumans

        // --- Color scanners need a YUV buffer like the camera provides.
        if let buffer = PixelBufferFactory.makeYUV420(from: cgImage) {
            let lamps = RoadSceneAnalyzer.diagnosticScanLamps(buffer)
            report.signalRed = lamps.red
            report.signalYellow = lamps.yellow
            report.signalGreen = lamps.green
            report.signalRegions = lamps.regions

            let pictograms = RoadSceneAnalyzer.diagnosticPictograms(buffer)
            report.schoolBlob = pictograms.school
            report.hospitalBlob = pictograms.hospital
            report.bikeBlob = pictograms.bike

            // Symbol signs are found by color+shape, not text.
            if pictograms.school,
               !report.signs.contains(where: { if case .schoolCrossing = $0 { return true } else { return false } }) {
                report.signs.append(.schoolCrossing(mph: nil))
            }
            if pictograms.hospital, !report.signs.contains(.hospital) {
                report.signs.append(.hospital)
            }
            if pictograms.bike, !report.signs.contains(.bikeLane) {
                report.signs.append(.bikeLane)
            }
        } else {
            report.notes.append("Could not convert image for color analysis.")
        }

        if report.ocrLines.isEmpty {
            report.notes.append(
                "No text recognized. Note: symbol signs (hospital H, bike route, school) carry no readable text — they are detected by sign colour and shape instead, shown as the chips above."
            )
        }
        if !report.ocrLines.isEmpty, report.signs.isEmpty {
            report.notes.append("Text was read but matched no sign pattern.")
        }
        return report
    }
}

/// Converts a CGImage into the bi-planar YCbCr format the camera produces,
/// so the live color scanners can run against imported images unchanged.
enum PixelBufferFactory {
    static func makeYUV420(from cgImage: CGImage) -> CVPixelBuffer? {
        // Cap size for speed; detection thresholds are resolution-relative.
        let maxWidth = 1920
        let scale = min(1.0, Double(maxWidth) / Double(cgImage.width))
        let width = (Int(Double(cgImage.width) * scale) / 2) * 2
        let height = (Int(Double(cgImage.height) * scale) / 2) * 2
        guard width > 1, height > 1 else { return nil }

        // Draw to RGBA first.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bufferOut: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &bufferOut
        ) == kCVReturnSuccess, let buffer = bufferOut else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }

        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // BT.601 video-range conversion (matches camera output).
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
                let yy = 16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255
                luma[y * lumaRow + x] = UInt8(max(0, min(255, yy)))
                if y % 2 == 0, x % 2 == 0 {
                    let cb = 128 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255
                    let cr = 128 + (112.0 * r - 93.786 * g - 18.214 * b) / 255
                    let index = (y / 2) * chromaRow + (x / 2) * 2
                    chroma[index] = UInt8(max(0, min(255, cb)))
                    chroma[index + 1] = UInt8(max(0, min(255, cr)))
                }
            }
        }
        return buffer
    }
}
