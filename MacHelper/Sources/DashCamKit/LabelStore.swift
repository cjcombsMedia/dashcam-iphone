import Foundation

/// Reads and writes label sets and the class list.
public final class LabelStore: @unchecked Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Classes

    /// Loads the class list, folding in any built-in classes added since the
    /// file was written.
    ///
    /// Returning the saved file verbatim would freeze the palette at whatever
    /// shipped the day it was created — new sign types would never appear.
    /// Replacing it wholesale would throw away classes the user added. So
    /// saved classes win on name, and new built-ins are appended.
    public func loadClasses() -> [LabelClass] {
        guard let data = try? Data(contentsOf: workspace.classesFile),
              let saved = try? Self.decoder().decode([LabelClass].self, from: data),
              !saved.isEmpty else {
            saveClasses(DefaultClasses.all)
            return DefaultClasses.all
        }

        let known = Set(saved.map(\.name))
        let added = DefaultClasses.all.filter { !known.contains($0.name) }
        guard !added.isEmpty else { return saved }

        let merged = saved + added
        saveClasses(merged)
        return merged
    }

    public func saveClasses(_ classes: [LabelClass]) {
        guard let data = try? Self.encoder().encode(classes) else { return }
        try? data.write(to: workspace.classesFile, options: .atomic)
    }

    // MARK: - Labels

    public func labelsURL(for clip: Clip) -> URL {
        workspace.labelsDirectory.appendingPathComponent(
            clip.url.deletingPathExtension().lastPathComponent + ".labels.json"
        )
    }

    /// Append-only change journal beside the labels file. Every edit is
    /// written here immediately, so a crash or force-quit loses nothing —
    /// the next open replays anything the saved file is missing.
    public func journalURL(for clip: Clip) -> URL {
        workspace.labelsDirectory.appendingPathComponent(
            clip.url.deletingPathExtension().lastPathComponent + ".journal.jsonl"
        )
    }

    public enum Change: String, Codable, Sendable {
        case upsert
        case delete
    }

    public struct JournalEntry: Codable, Sendable {
        public var change: Change
        public var label: FrameLabel
        public var at: Date
    }

    public func load(for clip: Clip) -> ClipLabels {
        var labels: ClipLabels
        if let data = try? Data(contentsOf: labelsURL(for: clip)),
           let decoded = try? Self.decoder().decode(ClipLabels.self, from: data) {
            labels = decoded
        } else {
            labels = ClipLabels(clipFileName: clip.fileName)
        }

        // Replay any journal entries the saved file doesn't already contain.
        guard let journal = try? String(contentsOf: journalURL(for: clip), encoding: .utf8) else {
            return labels
        }
        let decoder = Self.decoder()
        var recovered = 0
        for line in journal.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(JournalEntry.self, from: data) else { continue }
            switch entry.change {
            case .upsert:
                if let index = labels.labels.firstIndex(where: { $0.id == entry.label.id }) {
                    if labels.labels[index] != entry.label {
                        labels.labels[index] = entry.label
                        recovered += 1
                    }
                } else {
                    labels.labels.append(entry.label)
                    recovered += 1
                }
            case .delete:
                if labels.labels.contains(where: { $0.id == entry.label.id }) {
                    labels.labels.removeAll { $0.id == entry.label.id }
                    recovered += 1
                }
            }
        }
        if recovered > 0 {
            // Fold the recovered work into the saved file straight away.
            save(labels, for: clip)
        }
        return labels
    }

    /// Records one edit immediately — cheap, and survives a crash.
    public func appendJournal(_ change: Change, label: FrameLabel, for clip: Clip) {
        let entry = JournalEntry(change: change, label: label, at: Date())
        guard var data = try? Self.encoder().encode(entry) else { return }
        // One entry per line.
        if let compact = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .appending("\n"),
            let lineData = compact.data(using: .utf8) {
            data = lineData
        }
        let url = journalURL(for: clip)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func save(_ labels: ClipLabels, for clip: Clip) {
        guard let data = try? Self.encoder().encode(labels) else { return }
        try? data.write(to: labelsURL(for: clip), options: .atomic)
        // The saved file is now authoritative; clear the journal.
        try? FileManager.default.removeItem(at: journalURL(for: clip))
    }

    public func labelCount(for clip: Clip) -> Int {
        load(for: clip).labels.count
    }

    // MARK: - Reviews of what the phone detected

    public func reviewURL(for clip: Clip) -> URL {
        workspace.labelsDirectory.appendingPathComponent(
            clip.url.deletingPathExtension().lastPathComponent + ".review.json"
        )
    }

    public func loadReview(for clip: Clip) -> ClipReview {
        guard let data = try? Data(contentsOf: reviewURL(for: clip)),
              let review = try? Self.decoder().decode(ClipReview.self, from: data) else {
            return ClipReview(clipFileName: clip.fileName)
        }
        return review
    }

    public func saveReview(_ review: ClipReview, for clip: Clip) {
        guard let data = try? Self.encoder().encode(review) else { return }
        try? data.write(to: reviewURL(for: clip), options: .atomic)
    }

    /// Every clip's reviews, for export.
    /// Removes everything this clip's labelling produced: drawn boxes, the
    /// crash-recovery journal, and the detection review.
    public func deleteWork(for clip: Clip) {
        for url in [labelsURL(for: clip), journalURL(for: clip), reviewURL(for: clip)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func allReviews() -> [(clip: Clip, review: ClipReview)] {
        workspace.clips().compactMap { clip in
            let review = loadReview(for: clip)
            return review.reviews.isEmpty ? nil : (clip, review)
        }
    }

    /// Every labelled clip in the workspace, for export.
    public func allLabels() -> [(clip: Clip, labels: ClipLabels)] {
        workspace.clips().compactMap { clip in
            let labels = load(for: clip)
            return labels.labels.isEmpty ? nil : (clip, labels)
        }
    }
}
