import Foundation
@testable import DashCam

/// In-memory FileSystem for StorageManager tests.
final class MockFileSystem: FileSystem {
    struct Entry {
        var size: Int64
        var createdAt: Date
    }

    private(set) var files: [String: Entry] = [:]
    private(set) var directories: Set<String> = []
    private(set) var removedPaths: [String] = []
    var freeSpaceValue: Int64 = 0

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    func addFile(_ url: URL, size: Int64, createdAt: Date) {
        files[key(url)] = Entry(size: size, createdAt: createdAt)
    }

    func hasFile(_ url: URL) -> Bool {
        files[key(url)] != nil
    }

    // MARK: - FileSystem

    func fileExists(at url: URL) -> Bool {
        files[key(url)] != nil || directories.contains(key(url))
    }

    func createDirectory(at url: URL) throws {
        directories.insert(key(url))
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let parent = key(url)
        return files.keys
            .filter { ($0 as NSString).deletingLastPathComponent == parent }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    func attributes(at url: URL) throws -> FileAttributes {
        guard let entry = files[key(url)] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return FileAttributes(size: entry.size, createdAt: entry.createdAt)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        guard let entry = files.removeValue(forKey: key(source)) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[key(destination)] = entry
    }

    func removeItem(at url: URL) throws {
        guard files.removeValue(forKey: key(url)) != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        removedPaths.append(key(url))
    }

    func freeSpace(at url: URL) throws -> Int64 {
        freeSpaceValue
    }
}
