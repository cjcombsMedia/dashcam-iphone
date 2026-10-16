import CoreGraphics
import CoreVideo
import Foundation

/// Per-frame color statistics fed to the detector: how much of the frame is
/// saturated emergency-red / emergency-blue, and where those pixels are.
struct EmergencyFrameStats {
    var time: TimeInterval
    var redFraction: Double
    var blueFraction: Double
    /// Union bounding box of qualifying pixels, normalized to buffer coords.
    var box: CGRect?
}

/// Published detection for the UI's green box overlay.
struct EmergencyDetection: Equatable {
    /// Normalized rect in (landscape) buffer coordinates.
    var box: CGRect
    var time: TimeInterval
}

/// Pure temporal logic for spotting emergency strobes. Fully offline.
///
/// Emergency lights *flash*; brake lights and tail lights are steady, and
/// turn signals flash amber (which reads as red-ish) but never blue. So:
/// - trigger when red AND blue are both flashing (US light bars), or
/// - when blue alone flashes rapidly (blue strobes don't occur in normal
///   traffic; this also covers blue-only jurisdictions).
/// Red-only flashing never triggers — that's a turn signal.
struct EmergencyLightDetector {
    static let presenceThreshold = 0.0015 // fraction of sampled pixels
    static let window: TimeInterval = 2.5
    static let tagCooldown: TimeInterval = 30

    struct Result {
        var activeBox: CGRect?
        var shouldTag: Bool
    }

    private var history: [(time: TimeInterval, red: Bool, blue: Bool)] = []
    private var lastTagTime: TimeInterval = -.infinity

    mutating func process(_ stats: EmergencyFrameStats) -> Result {
        let red = stats.redFraction >= Self.presenceThreshold
        let blue = stats.blueFraction >= Self.presenceThreshold
        history.append((stats.time, red, blue))
        history.removeAll { $0.time < stats.time - Self.window }

        var redFlips = 0
        var blueFlips = 0
        for (previous, current) in zip(history, history.dropFirst()) {
            if previous.red != current.red { redFlips += 1 }
            if previous.blue != current.blue { blueFlips += 1 }
        }

        let bothFlashing = redFlips >= 2 && blueFlips >= 2
        let strongBlueStrobe = blueFlips >= 4
        let active = (bothFlashing || strongBlueStrobe) && (red || blue)

        var shouldTag = false
        if active, stats.time - lastTagTime >= Self.tagCooldown {
            lastTagTime = stats.time
            shouldTag = true
        }
        return Result(activeBox: active ? stats.box : nil, shouldTag: shouldTag)
    }
}

/// Scans a camera pixel buffer for saturated red/blue clusters. Works
/// directly on the native bi-planar YCbCr format — red is high Cr / low Cb,
/// blue is high Cb / low Cr — so no color conversion or ML model is needed
/// and a sparse grid keeps the cost near-zero even at 4K.
enum EmergencyFrameAnalyzer {
    /// `excluding`: normalized regions (steady traffic-signal lamps) whose
    /// samples are skipped, so signals never read as emergency lights.
    static func scan(
        _ pixelBuffer: CVPixelBuffer,
        at time: TimeInterval,
        excluding: [CGRect] = []
    ) -> EmergencyFrameStats? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard chromaWidth > 0, chromaHeight > 0 else { return nil }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // ~64x36 sample grid regardless of resolution.
        let stepX = max(1, chromaWidth / 64)
        let stepY = max(1, chromaHeight / 36)

        var total = 0
        var redCount = 0
        var blueCount = 0
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0

        var y = 0
        while y < chromaHeight {
            var x = 0
            while x < chromaWidth {
                total += 1
                let nxPoint = Double(x) / Double(chromaWidth)
                let nyPoint = Double(y) / Double(chromaHeight)
                if excluding.contains(where: { $0.contains(CGPoint(x: nxPoint, y: nyPoint)) }) {
                    x += stepX
                    continue
                }
                let cb = chroma[y * chromaRowBytes + 2 * x]
                let cr = chroma[y * chromaRowBytes + 2 * x + 1]
                let brightness = luma[(2 * y) * lumaRowBytes + 2 * x]

                // Emergency LEDs are BRIGHT with strong color cast; their
                // centers bloom toward white, so demand brightness but
                // accept moderately saturated chroma (the colored halo).
                // The Cb floor keeps amber (signal housings, turn signals,
                // warning signs) out of the red class entirely.
                let isRed = cr >= 175 && cb >= 78 && cb <= 125 && brightness >= 60
                let isBlue = cb >= 160 && cr <= 130 && brightness >= 60

                if isRed || isBlue {
                    if isRed { redCount += 1 }
                    if isBlue { blueCount += 1 }
                    let nx = Double(x) / Double(chromaWidth)
                    let ny = Double(y) / Double(chromaHeight)
                    minX = min(minX, nx)
                    minY = min(minY, ny)
                    maxX = max(maxX, nx)
                    maxY = max(maxY, ny)
                }
                x += stepX
            }
            y += stepY
        }

        guard total > 0 else { return nil }

        var box: CGRect?
        if redCount + blueCount > 0 {
            // Pad by one grid cell so the box comfortably encloses the lights.
            let padX = Double(stepX) / Double(chromaWidth)
            let padY = Double(stepY) / Double(chromaHeight)
            box = CGRect(
                x: max(0, minX - padX),
                y: max(0, minY - padY),
                width: min(1, maxX - minX + 2 * padX),
                height: min(1, maxY - minY + 2 * padY)
            )
        }

        return EmergencyFrameStats(
            time: time,
            redFraction: Double(redCount) / Double(total),
            blueFraction: Double(blueCount) / Double(total),
            box: box
        )
    }
}
