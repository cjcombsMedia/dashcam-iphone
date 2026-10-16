import Foundation

/// Where everything lives on the Mac.
///
/// ~/Movies/DashCam/
///   <date>/            received clips + telemetry sidecars
///   Labels/            one .labels.json per clip
///   Export/            roadmemory.json, training datasets
///   classes.json       the label class list (editable)
public struct Workspace: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DashCam", isDirectory: true)
        ensureDirectories()
    }

    public var labelsDirectory: URL { root.appendingPathComponent("Labels", isDirectory: true) }
    public var exportDirectory: URL { root.appendingPathComponent("Export", isDirectory: true) }
    public var classesFile: URL { root.appendingPathComponent("classes.json") }
    public var roadMemoryFile: URL { exportDirectory.appendingPathComponent("roadmemory.json") }

    private func ensureDirectories() {
        for url in [root, labelsDirectory, exportDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Every received clip, newest first, with its sidecar if present.
    public func clips() -> [Clip] {
        let fm = FileManager.default
        guard let dayFolders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Clip] = []
        for folder in dayFolders {
            let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory,
                  !["Labels", "Export"].contains(folder.lastPathComponent),
                  let files = try? fm.contentsOfDirectory(
                      at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }

            for file in files where ["mp4", "mov"].contains(file.pathExtension.lowercased()) {
                let sidecar = file.deletingPathExtension().appendingPathExtension("json")
                let values = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                found.append(Clip(
                    url: file,
                    sidecarURL: fm.fileExists(atPath: sidecar.path) ? sidecar : nil,
                    createdAt: values?.creationDate ?? .distantPast,
                    byteSize: Int64(values?.fileSize ?? 0)
                ))
            }
        }
        return found.sorted { $0.createdAt > $1.createdAt }
    }
}

public struct Clip: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let sidecarURL: URL?
    public let createdAt: Date
    public let byteSize: Int64

    public var fileName: String { url.lastPathComponent }

    public func loadSidecar() -> TelemetrySidecar? {
        guard let sidecarURL, let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? TelemetrySidecar.decoder().decode(TelemetrySidecar.self, from: data)
    }
}
