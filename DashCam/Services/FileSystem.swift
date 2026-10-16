import Foundation

struct FileAttributes: Equatable {
    var size: Int64
    var createdAt: Date
}

/// Abstraction over the pieces of FileManager that StorageManager needs, so
/// the loop-buffer logic is unit-testable against an in-memory mock.
protocol FileSystem {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func attributes(at url: URL) throws -> FileAttributes
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func freeSpace(at url: URL) throws -> Int64
}

struct DefaultFileSystem: FileSystem {
    private let fm = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
    }

    func attributes(at url: URL) throws -> FileAttributes {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        return FileAttributes(
            size: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate ?? .distantPast
        )
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fm.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    func freeSpace(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
