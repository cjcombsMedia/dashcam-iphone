import Foundation

/// Owns the two-folder model and the loop-buffer storage budget.
///
/// Budget rule: total app footage (LOOP + SAVED) may never exceed 75% of
/// (current free space + space the footage already occupies). Recalculated
/// before each new segment. Oldest LOOP segments are deleted to make room;
/// SAVED is never touched.
final class StorageManager {
    enum PreflightResult: Equatable {
        /// OK to record the next segment. `prunedFiles` are the loop video
        /// file names deleted to make room (their sidecars went with them).
        case ready(prunedFiles: [String])
        /// Even an empty LOOP can't fit the next segment. Stop and alert.
        case stopRecording
    }

    static let budgetFraction = 0.75
    static let minLoopMinutes = 30.0
    static let videoExtensions: Set<String> = ["mov", "mp4"]

    let rootURL: URL
    private let fs: FileSystem

    /// Debug override: when set, reported free space is clamped to this value
    /// so the full-disk path is testable on any device.
    var simulatedFreeSpace: Int64?

    init(rootURL: URL, fileSystem: FileSystem = DefaultFileSystem()) {
        self.rootURL = rootURL
        self.fs = fileSystem
    }

    var loopURL: URL { rootURL.appendingPathComponent(StorageFolder.loop.rawValue, isDirectory: true) }
    var savedURL: URL { rootURL.appendingPathComponent(StorageFolder.saved.rawValue, isDirectory: true) }

    func url(for folder: StorageFolder) -> URL {
        folder == .loop ? loopURL : savedURL
    }

    func url(forFileName fileName: String, in folder: StorageFolder) -> URL {
        url(for: folder).appendingPathComponent(fileName)
    }

    /// Deletes scratch files that no longer belong to anything: half-finished
    /// remuxes left behind by a crash, and stale export temporaries. Real
    /// footage and telemetry are never touched.
    ///
    /// - Returns: bytes reclaimed.
    @discardableResult
    func clearCaches() -> Int64 {
        var freed: Int64 = 0
        let prefixes = [".optimizing-", ".incoming-", ".export-"]
        var directories = StorageFolder.allCases.map { url(for: $0) }
        directories.append(FileManager.default.temporaryDirectory)

        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: []
            ) else { continue }
            for entry in entries where prefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                if (try? FileManager.default.removeItem(at: entry)) != nil {
                    freed += size
                }
            }
        }
        DiagLog.shared.info("Cache clear: reclaimed \(freed) bytes of scratch files")
        return freed
    }

    func ensureFolders() throws {
        for folder in StorageFolder.allCases {
            let url = self.url(for: folder)
            if !fs.fileExists(at: url) {
                try fs.createDirectory(at: url)
            }
        }
    }

    // MARK: - Measurement

    private func files(in folder: StorageFolder) -> [URL] {
        (try? fs.contentsOfDirectory(at: url(for: folder))) ?? []
    }

    /// Video files in a folder, oldest first.
    func videoFilesOldestFirst(in folder: StorageFolder) -> [(url: URL, attributes: FileAttributes)] {
        files(in: folder)
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let attributes = try? fs.attributes(at: url) else { return nil }
                return (url, attributes)
            }
            .sorted { $0.attributes.createdAt < $1.attributes.createdAt }
    }

    /// Total bytes in a folder, including telemetry sidecars.
    func folderBytes(_ folder: StorageFolder) -> Int64 {
        files(in: folder).reduce(0) { total, url in
            total + ((try? fs.attributes(at: url))?.size ?? 0)
        }
    }

    func freeSpace() -> Int64 {
        let actual = (try? fs.freeSpace(at: rootURL)) ?? 0
        if let simulated = simulatedFreeSpace {
            return min(actual, simulated)
        }
        return actual
    }

    // MARK: - Budget

    /// The byte ceiling for all app footage under the 75% rule, given current
    /// free space and existing footage.
    func allowedFootageBytes() -> Int64 {
        let footage = folderBytes(.loop) + folderBytes(.saved)
        return Int64(Double(freeSpace() + footage) * Self.budgetFraction)
    }

    /// Recalculates the budget and prunes oldest LOOP segments (and their
    /// sidecars) until the next segment fits. Never touches SAVED.
    func prepareForNextSegment(estimatedBytes: Int64) throws -> PreflightResult {
        try ensureFolders()

        // Deleting a loop file moves its bytes from "footage" to "free space",
        // so the (free + footage) sum — and therefore the ceiling — is stable
        // across the prune loop and can be computed once.
        let allowed = allowedFootageBytes()
        let savedBytes = folderBytes(.saved)
        var loopBytes = folderBytes(.loop)
        var pruned: [String] = []

        var loopVideos = videoFilesOldestFirst(in: .loop)
        while loopBytes + savedBytes + estimatedBytes > allowed, !loopVideos.isEmpty {
            let oldest = loopVideos.removeFirst()
            var reclaimed = oldest.attributes.size
            let sidecar = Self.sidecarURL(forVideo: oldest.url)
            if fs.fileExists(at: sidecar) {
                reclaimed += (try? fs.attributes(at: sidecar))?.size ?? 0
                try? fs.removeItem(at: sidecar)
            }
            try fs.removeItem(at: oldest.url)
            loopBytes -= reclaimed
            pruned.append(oldest.url.lastPathComponent)
        }

        if loopBytes + savedBytes + estimatedBytes > allowed {
            return .stopRecording
        }
        return .ready(prunedFiles: pruned)
    }

    /// True when SAVED growth has squeezed the loop's share of the budget
    /// below ~30 minutes at the given resolution.
    func isLoopCapacityLow(resolution: VideoResolution) -> Bool {
        estimatedLoopMinutes(resolution: resolution) < Self.minLoopMinutes
    }

    /// Minutes of loop recording the current budget allows (the loop's share
    /// is whatever the SAVED folder hasn't consumed).
    func estimatedLoopMinutes(resolution: VideoResolution) -> Double {
        let loopBudget = max(0, allowedFootageBytes() - folderBytes(.saved))
        return Double(loopBudget) / Double(resolution.estimatedBytesPerSecond) / 60.0
    }

    // MARK: - File operations

    static func sidecarURL(forVideo url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    /// Moves a segment and its sidecar from LOOP to SAVED.
    func moveToSaved(fileName: String, sidecarFileName: String?) throws {
        try ensureFolders()
        try fs.moveItem(
            at: url(forFileName: fileName, in: .loop),
            to: url(forFileName: fileName, in: .saved)
        )
        if let sidecarFileName {
            let source = url(forFileName: sidecarFileName, in: .loop)
            if fs.fileExists(at: source) {
                try fs.moveItem(at: source, to: url(forFileName: sidecarFileName, in: .saved))
            }
        }
    }

    func delete(fileName: String, sidecarFileName: String?, from folder: StorageFolder) throws {
        let video = url(forFileName: fileName, in: folder)
        if fs.fileExists(at: video) {
            try fs.removeItem(at: video)
        }
        if let sidecarFileName {
            let sidecar = url(forFileName: sidecarFileName, in: folder)
            if fs.fileExists(at: sidecar) {
                try fs.removeItem(at: sidecar)
            }
        }
    }

    func fileExists(fileName: String, in folder: StorageFolder) -> Bool {
        fs.fileExists(at: url(forFileName: fileName, in: folder))
    }

    func fileSize(fileName: String, in folder: StorageFolder) -> Int64 {
        (try? fs.attributes(at: url(forFileName: fileName, in: folder)))?.size ?? 0
    }
}
