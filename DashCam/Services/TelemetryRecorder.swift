import Foundation

/// Collects 1 Hz telemetry samples while recording and writes one JSON
/// sidecar per video segment. File I/O happens off the main thread.
final class TelemetryRecorder {
    private var timer: Timer?
    private var samples: [TelemetrySample] = []
    private let writeQueue = DispatchQueue(label: "com.cjcombs.dashcam.telemetry", qos: .utility)

    /// Supplies the current sample; called on the main run loop at 1 Hz.
    var sampleProvider: (() -> TelemetrySample)?

    /// Each 1 Hz sample as it is taken. The owner files it against whichever
    /// segment is recording right now — samples are never held here waiting
    /// to be claimed, so a segment can't be finalised before its telemetry
    /// has been handed over.
    var onSample: ((TelemetrySample) -> Void)?

    var isRunning: Bool { timer != nil }

    func begin() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let provider = self.sampleProvider else { return }
            let sample = provider()
            self.samples.append(sample)
            self.onSample?(sample)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops collection entirely.
    func end() {
        timer?.invalidate()
        timer = nil
        samples.removeAll()
    }

    /// Writes a sidecar JSON file for a finished segment. Completion runs on
    /// the main queue with the sidecar file name on success.
    func writeSidecar(
        samples: [TelemetrySample],
        emergencyEvents: [EmergencyEvent] = [],
        signalEvents: [SignalEvent] = [],
        overlaySnapshots: [OverlaySnapshot] = [],
        segmentFileName: String,
        resolution: VideoResolution,
        startedAt: Date,
        directory: URL,
        completion: @escaping (String?) -> Void
    ) {
        writeQueue.async {
            let sidecar = TelemetrySidecar(
                segmentFileName: segmentFileName,
                resolution: resolution.rawValue,
                startedAt: startedAt,
                samples: samples,
                emergencyEvents: emergencyEvents.isEmpty ? nil : emergencyEvents,
                signalEvents: signalEvents.isEmpty ? nil : signalEvents,
                overlaySnapshots: overlaySnapshots.isEmpty ? nil : overlaySnapshots
            )
            let fileName = (segmentFileName as NSString).deletingPathExtension + ".json"
            let url = directory.appendingPathComponent(fileName)
            do {
                let data = try TelemetrySidecar.encoder().encode(sidecar)
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { completion(fileName) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
