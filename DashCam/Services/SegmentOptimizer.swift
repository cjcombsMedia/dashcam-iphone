import AVFoundation
import Foundation

/// Remuxes finalized segments from their crash-safe fragmented QuickTime
/// form into a flat **.mp4** so the player opens them instantly and shared
/// originals play anywhere.
///
/// Passthrough only — samples are copied, never re-encoded. Background jobs
/// run one at a time at utility priority; the player uses `optimizeNow`,
/// an express lane that never waits behind the background queue.
final class SegmentOptimizer {
    struct Result {
        let fileName: String
        let bytes: Int64
    }

    static let shared = SegmentOptimizer()

    private var chain: Task<Void, Never>?

    /// Queues a background optimization. `completion` runs on the main queue
    /// with the new file name/size, or nil on failure (original untouched).
    func optimize(fileURL: URL, completion: @escaping @MainActor (Result?) -> Void) {
        let previous = chain
        chain = Task(priority: .utility) {
            await previous?.value
            let result = await Self.remux(fileURL: fileURL)
            await completion(result)
        }
    }

    /// Express lane for the player: runs immediately, in parallel with any
    /// background queue, so opening a clip never waits behind other jobs.
    /// (A duplicate background job for the same file stays harmless — the
    /// remux is idempotent.)
    func optimizeNow(fileURL: URL) async -> Result? {
        await Task.detached(priority: .userInitiated) {
            await Self.remux(fileURL: fileURL)
        }.value
    }

    private static func remux(fileURL: URL) async -> Result? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }

        let asset = AVURLAsset(url: fileURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            DiagLog.shared.error("Optimizer: no passthrough export session for \(fileURL.lastPathComponent)")
            return nil
        }

        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let tempURL = directory.appendingPathComponent(".optimizing-\(UUID().uuidString).mp4")
        let destinationURL = directory.appendingPathComponent("\(baseName).mp4")

        if #available(iOS 18.0, *) {
            do {
                try await export.export(to: tempURL, as: .mp4)
            } catch {
                DiagLog.shared.error("Optimizer: remux failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
                try? fm.removeItem(at: tempURL)
                return nil
            }
        } else {
            export.outputURL = tempURL
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await export.export()
            guard export.status == .completed else {
                DiagLog.shared.error(
                    "Optimizer: remux failed for \(fileURL.lastPathComponent): \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")"
                )
                try? fm.removeItem(at: tempURL)
                return nil
            }
        }

        do {
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destinationURL)
            }
            if destinationURL != fileURL, fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: fileURL)
            }
            let size = Int64((try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            DiagLog.shared.info("Optimizer: \(destinationURL.lastPathComponent) ready (flat MP4, \(size) bytes)")
            return Result(fileName: destinationURL.lastPathComponent, bytes: size)
        } catch {
            DiagLog.shared.error("Optimizer: could not place optimized file for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            try? fm.removeItem(at: tempURL)
            return nil
        }
    }
}
