import AVFoundation
import CoreImage
import Foundation

/// Turns labelled frames into the two things that improve the phone:
/// road-memory features it can recall by GPS, and a training dataset for
/// the on-device detector.
public enum Exporters {

    // MARK: - Road memory (what the phone imports and recalls)

    public struct MemoryResult: Sendable {
        public var featureCount: Int
        public var skippedNoGPS: Int
        public var url: URL
    }

    /// A label drawn at 00:42 becomes a feature at the GPS position the car
    /// held at 00:42 — that's how a box on a video turns into something the
    /// phone can recall on the next drive.
    @discardableResult
    public static func exportRoadMemory(
        store: LabelStore,
        classes: [LabelClass]
    ) throws -> MemoryResult {
        let byName = Dictionary(uniqueKeysWithValues: classes.map { ($0.name, $0) })
        var features: [RoadFeatureExport] = []
        var skipped = 0

        /// Turns a (time, class, value) into a placed feature using the GPS
        /// the car held at that instant.
        func makeFeature(
            sidecar: TelemetrySidecar, time: Double, className: String, value: String?
        ) -> RoadFeatureExport? {
            guard let memoryType = byName[className]?.memoryType else { return nil }
            guard let sample = sidecar.sample(atOffset: time),
                  let latitude = sample.latitude,
                  let longitude = sample.longitude,
                  let heading = sample.headingDegrees, heading >= 0 else {
                skipped += 1
                return nil
            }
            return RoadFeatureExport(
                type: memoryType, value: value,
                latitude: latitude, longitude: longitude, heading: heading
            )
        }

        // Boxes drawn by hand.
        for (clip, labels) in store.allLabels() {
            guard let sidecar = clip.loadSidecar() else {
                skipped += labels.labels.count
                continue
            }
            for label in labels.labels {
                if let feature = makeFeature(
                    sidecar: sidecar, time: label.time,
                    className: label.className, value: label.value
                ) {
                    features.append(feature)
                }
            }
        }

        // Phone detections you confirmed or corrected — reviewing alone is
        // enough to teach the phone a place; no box required.
        for (clip, review) in store.allReviews() {
            guard let sidecar = clip.loadSidecar() else { continue }
            for entry in review.reviews where entry.verdict != .rejected {
                if let feature = makeFeature(
                    sidecar: sidecar, time: entry.time,
                    className: entry.className, value: entry.value
                ) {
                    features.append(feature)
                }
            }
        }

        // Drop anything the driver removed on the phone. Without this the
        // Mac keeps re-exporting a sign that was deliberately deleted, and
        // the next import puts it back.
        let forgotten = ForgottenStore.load(from: store.workspace)
        if !forgotten.isEmpty {
            features = features.filter { feature in
                !ForgottenStore.isBuried(
                    type: feature.type, latitude: feature.latitude,
                    longitude: feature.longitude, heading: feature.heading,
                    by: forgotten
                )
            }
        }

        // Collapse duplicates: same type within ~70 m on a similar heading.
        var deduped: [RoadFeatureExport] = []
        for feature in features {
            let isDuplicate = deduped.contains { existing in
                existing.type == feature.type
                    && headingDelta(existing.heading, feature.heading) <= 50
                    && distance(
                        existing.latitude, existing.longitude,
                        feature.latitude, feature.longitude
                    ) <= 70
            }
            if !isDuplicate { deduped.append(feature) }
        }

        let export = RoadMemoryExport(features: deduped)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        try data.write(to: store.workspace.roadMemoryFile, options: .atomic)

        return MemoryResult(
            featureCount: deduped.count,
            skippedNoGPS: skipped,
            url: store.workspace.roadMemoryFile
        )
    }

    // MARK: - Training dataset (Create ML object detection)

    public struct DatasetResult: Sendable {
        public var imageCount: Int
        public var annotationCount: Int
        public var url: URL
    }

    private struct CreateMLAnnotation: Codable {
        struct Coordinates: Codable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
        }
        var label: String
        var coordinates: Coordinates
    }

    private struct CreateMLEntry: Codable {
        var image: String
        var annotations: [CreateMLAnnotation]
    }

    /// Writes Export/TrainingData-<stamp>/ containing one JPEG per labelled
    /// frame plus annotations.json in Create ML's object-detection format.
    public static func exportTrainingDataset(
        store: LabelStore,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DatasetResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let directory = store.workspace.exportDirectory
            .appendingPathComponent("TrainingData-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let work = store.allLabels()
        var entries: [CreateMLEntry] = []
        var annotationCount = 0
        var frameIndex = 0

        let context = CIContext()

        for (clipIndex, item) in work.enumerated() {
            let asset = AVURLAsset(url: item.clip.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            // One image per labelled frame time; all boxes on that frame
            // become its annotations.
            let byTime = Dictionary(grouping: item.labels.labels) { ($0.time * 10).rounded() / 10 }

            for (time, labels) in byTime.sorted(by: { $0.key < $1.key }) {
                guard let (cgImage, _) = try? await generator.image(
                    at: CMTime(seconds: time, preferredTimescale: 600)
                ) else { continue }

                let width = Double(cgImage.width)
                let height = Double(cgImage.height)
                let name = "frame-\(String(format: "%05d", frameIndex)).jpg"
                frameIndex += 1

                let ciImage = CIImage(cgImage: cgImage)
                guard let jpeg = context.jpegRepresentation(
                    of: ciImage,
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
                ) else { continue }
                try jpeg.write(to: directory.appendingPathComponent(name))

                // Create ML wants CENTRE x/y in pixels.
                let annotations = labels.map { label in
                    CreateMLAnnotation(
                        label: label.className,
                        coordinates: .init(
                            x: (label.x + label.width / 2) * width,
                            y: (label.y + label.height / 2) * height,
                            width: label.width * width,
                            height: label.height * height
                        )
                    )
                }
                annotationCount += annotations.count
                entries.append(CreateMLEntry(image: name, annotations: annotations))
            }
            progress?(Double(clipIndex + 1) / Double(max(1, work.count)))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: directory.appendingPathComponent("annotations.json"), options: .atomic)

        return DatasetResult(
            imageCount: entries.count,
            annotationCount: annotationCount,
            url: directory
        )
    }

    // MARK: - Geo helpers (mirrors the phone's matching rules)

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    static func headingDelta(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta
    }
}
