import Foundation

/// One sign the driver removed from road memory by long-pressing it on the
/// phone's live view.
public struct ForgottenFeatureRecord: Codable, Equatable, Sendable {
    public var type: String
    public var latitude: Double
    public var longitude: Double
    public var heading: Double
    public var forgottenAt: Date

    public init(
        type: String, latitude: Double, longitude: Double,
        heading: Double, forgottenAt: Date
    ) {
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.forgottenAt = forgottenAt
    }
}

/// The Mac's record of what the driver has removed.
///
/// Without this the loop never closes: the phone forgets a sign, the Mac
/// exports it again from its labels, and the next import puts it straight
/// back. Every road-memory export is filtered through these, so a removal
/// made once on the road stays made.
public enum ForgottenStore {
    public static func fileURL(in workspace: Workspace) -> URL {
        workspace.root.appendingPathComponent("forgotten.json")
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load(from workspace: Workspace) -> [ForgottenFeatureRecord] {
        guard let data = try? Data(contentsOf: fileURL(in: workspace)) else { return [] }
        return (try? decoder().decode([ForgottenFeatureRecord].self, from: data)) ?? []
    }

    /// Adds new removals, ignoring ones already recorded.
    ///
    /// - Returns: the total number held afterwards.
    @discardableResult
    public static func merge(
        _ incoming: [ForgottenFeatureRecord],
        in workspace: Workspace
    ) throws -> Int {
        var all = load(from: workspace)
        for record in incoming {
            let known = all.contains { existing in
                existing.type == record.type && isSamePlace(existing, record)
            }
            if !known { all.append(record) }
        }
        try FileManager.default.createDirectory(
            at: workspace.root, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: fileURL(in: workspace), options: .atomic)
        return all.count
    }

    /// True when a feature about to be exported was removed on the phone.
    public static func isBuried(
        type: String, latitude: Double, longitude: Double, heading: Double,
        by records: [ForgottenFeatureRecord]
    ) -> Bool {
        records.contains { record in
            record.type == type && isSamePlace(
                record,
                ForgottenFeatureRecord(
                    type: type, latitude: latitude, longitude: longitude,
                    heading: heading, forgottenAt: record.forgottenAt
                )
            )
        }
    }

    /// Same place, same direction of travel — the phone's matching rules.
    private static func isSamePlace(
        _ a: ForgottenFeatureRecord, _ b: ForgottenFeatureRecord
    ) -> Bool {
        Exporters.headingDelta(a.heading, b.heading) <= 50
            && Exporters.distance(a.latitude, a.longitude, b.latitude, b.longitude) <= 70
    }
}
