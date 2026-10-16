import Foundation
import SwiftData

/// Remembers road features by place and direction, so familiar routes show
/// their signs even when the camera can't read them.
///
/// Learning rule: a detected feature is stored on first sighting but only
/// *used* once confirmed a second time — one bad read never sticks. Manual
/// entries are authoritative and are never overwritten by detection.
@MainActor
final class RoadMemory: ObservableObject {
    /// Features currently approaching, newest match first.
    @Published private(set) var active: [RoadFeature] = []
    /// Feature IDs currently supplying an on-screen sign (for the M badge).
    @Published private(set) var activeTypes: Set<RoadFeatureType> = []

    private let modelContext: ModelContext
    private var cache: [RoadFeature] = []
    private var cacheLoaded = false
    /// Avoids re-announcing the same feature while still inside its range.
    private var announced: Set<UUID> = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Storage

    func allFeatures() -> [RoadFeature] {
        (try? modelContext.fetch(
            FetchDescriptor<RoadFeature>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        )) ?? []
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cache = allFeatures()
        cacheLoaded = true
    }

    private func invalidateCache() {
        cacheLoaded = false
    }

    // MARK: - Learning

    /// Records a live detection. Returns the feature it created or updated.
    @discardableResult
    func learn(
        type: RoadFeatureType,
        value: String?,
        latitude: Double,
        longitude: Double,
        heading: Double
    ) -> RoadFeature? {
        guard heading >= 0 else { return nil }
        // A sign the owner removed by hand stays removed. Without this the
        // camera relearns it on the very next pass and the long-press does
        // nothing that lasts.
        guard !isBuried(type: type, latitude: latitude, longitude: longitude, heading: heading) else {
            return nil
        }
        loadCacheIfNeeded()

        if let existing = cache.first(where: { feature in
            feature.type == type && GeoMatch.isSameFeature(
                existingLat: feature.latitude, existingLon: feature.longitude,
                existingHeading: feature.heading,
                newLat: latitude, newLon: longitude, newHeading: heading
            )
        }) {
            existing.confirmCount += 1
            existing.lastSeenAt = Date()
            // Detection may correct itself, but never overrides a manual edit.
            if existing.source == .detected, let value, existing.value != value {
                existing.value = value
                DiagLog.shared.info("Memory: updated \(type.rawValue) to \(value)")
            }
            try? modelContext.save()
            return existing
        }

        let feature = RoadFeature(
            type: type,
            value: value,
            latitude: latitude,
            longitude: longitude,
            heading: heading,
            source: .detected
        )
        modelContext.insert(feature)
        try? modelContext.save()
        invalidateCache()
        DiagLog.shared.info("Memory: learned \(type.rawValue)\(value.map { " \($0)" } ?? "")")
        return feature
    }

    /// Adds a feature by hand at the current position — for signs the camera
    /// will never read. Manual entries are trusted immediately.
    @discardableResult
    func addManual(
        type: RoadFeatureType,
        value: String?,
        latitude: Double,
        longitude: Double,
        heading: Double
    ) -> RoadFeature {
        let feature = RoadFeature(
            type: type,
            value: value,
            latitude: latitude,
            longitude: longitude,
            heading: max(0, heading),
            source: .manual
        )
        modelContext.insert(feature)
        try? modelContext.save()
        invalidateCache()
        DiagLog.shared.info("Memory: manually added \(type.rawValue)")
        return feature
    }

    func update(_ feature: RoadFeature, value: String?) {
        feature.value = value
        feature.source = .manual // an edit makes it authoritative
        try? modelContext.save()
        invalidateCache()
    }

    func setEnabled(_ feature: RoadFeature, _ enabled: Bool) {
        feature.enabled = enabled
        try? modelContext.save()
        invalidateCache()
    }

    func delete(_ feature: RoadFeature) {
        modelContext.delete(feature)
        try? modelContext.save()
        invalidateCache()
        announced.remove(feature.id)
    }

    /// Removes the remembered sign of this type that is on screen right now,
    /// and leaves a tombstone so neither a Mac import nor a fresh camera
    /// sighting can quietly bring it back.
    ///
    /// - Returns: what was removed, for the confirmation message.
    @discardableResult
    func forgetActive(type: RoadFeatureType) -> RoadFeature? {
        guard let feature = active.first(where: { $0.type == type }) else { return nil }

        let tombstone = ForgottenFeature(
            type: type,
            latitude: feature.latitude,
            longitude: feature.longitude,
            heading: feature.heading
        )
        modelContext.insert(tombstone)
        modelContext.delete(feature)
        try? modelContext.save()
        invalidateCache()
        announced.remove(feature.id)
        DiagLog.shared.info(
            "Memory: forgot \(type.rawValue) at \(feature.latitude),\(feature.longitude) — tombstoned"
        )
        return feature
    }

    /// Every tombstone on this phone.
    func tombstones() -> [ForgottenFeature] {
        (try? modelContext.fetch(FetchDescriptor<ForgottenFeature>())) ?? []
    }

    /// True when a feature arriving from the Mac was deliberately removed
    /// here and must not be re-added.
    func isBuried(type: RoadFeatureType, latitude: Double, longitude: Double, heading: Double) -> Bool {
        tombstones().contains {
            $0.buries(type: type, latitude: latitude, longitude: longitude, heading: heading)
        }
    }

    func markTombstonesSynced(_ tombstones: [ForgottenFeature]) {
        for tombstone in tombstones { tombstone.syncedToDesktop = true }
        try? modelContext.save()
    }

    func deleteAll() {
        for feature in allFeatures() {
            modelContext.delete(feature)
        }
        try? modelContext.save()
        invalidateCache()
        announced.removeAll()
    }

    // MARK: - Recall

    /// Called ~1 Hz with the current fix. Returns features newly entered
    /// (for chimes); `active` holds everything currently in range.
    @discardableResult
    func updatePosition(latitude: Double, longitude: Double, heading: Double) -> [RoadFeature] {
        loadCacheIfNeeded()
        guard heading >= 0 else { return [] }

        let matches = cache.filter { feature in
            feature.enabled && feature.isTrusted && GeoMatch.isApproaching(
                currentLat: latitude, currentLon: longitude, currentHeading: heading,
                featureLat: feature.latitude, featureLon: feature.longitude,
                featureHeading: feature.heading,
                triggerDistance: feature.type.triggerDistance
            )
        }

        let matchedIDs = Set(matches.map(\.id))
        let entered = matches.filter { !announced.contains($0.id) }
        announced = announced.intersection(matchedIDs).union(matchedIDs)

        active = matches
        activeTypes = Set(matches.map(\.type))
        return entered
    }

    /// Distance in meters from a position to a feature (for the editor).
    func distance(from latitude: Double, _ longitude: Double, to feature: RoadFeature) -> Double {
        GeoMatch.distance(
            fromLat: latitude, fromLon: longitude,
            toLat: feature.latitude, toLon: feature.longitude
        )
    }
}
