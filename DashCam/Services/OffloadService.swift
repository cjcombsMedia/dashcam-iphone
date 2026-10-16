import CryptoKit
import Foundation
import Network
import SwiftData
import UIKit

/// Finds the Mac offload helper on the local network (Bonjour) and uploads
/// footage to it over LAN HTTP. Every file is SHA-256 verified by the Mac
/// before the phone deletes its copy — the phone never deletes anything the
/// Mac hasn't provably received intact.
///
/// Uploads run in a background URLSession, so a transfer in progress keeps
/// going if the phone is locked; deletion happens when the app is next
/// active and the verification responses have been processed.
@MainActor
final class OffloadService: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case searching
        case ready(String)
        case offloading(done: Int, total: Int)
        case finished(clips: Int, bytes: Int64)
        case failed(String)
    }

    /// A file currently in flight, for the progress list.
    struct UploadProgress: Identifiable, Equatable {
        let id: String
        var fileName: String
        var bytesSent: Int64
        var totalBytes: Int64

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(bytesSent) / Double(totalBytes)) : 0
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var helperFound = false
    /// Live per-file progress — a single 4K segment can take a while, and
    /// without this the run looks stuck between file completions.
    @Published private(set) var activeUploads: [UploadProgress] = []

    /// What the last run did, kept for Settings after the on-screen banner
    /// has auto-dismissed.
    @Published private(set) var lastRunSummary: String?
    /// True when the last finished run sent copies and left the originals on
    /// the phone, so the banner doesn't claim space was reclaimed.
    @Published private(set) var lastRunWasCopy = false

    /// True while a run is in flight — a second run can't be started on top
    /// of it, so the Library's Offload button dims.
    @Published private(set) var isBusy = false

    var isRecordingProvider: () -> Bool = { false }
    /// Set by the app so imported features land in road memory.
    var roadMemory: RoadMemory?
    @Published var importMessage: String?

    private let settings: AppSettings
    private let storage: StorageManager
    private let tagStore: TagStore
    private let modelContext: ModelContext

    private var browser: NWBrowser?
    private var resolveConnection: NWConnection?
    private var baseURL: URL?
    private var session: URLSession!
    private var watchdog: Timer?
    private var helperName: String?
    /// Clears a finished/failed banner after a grace period.
    private var bannerResetTask: Task<Void, Never>?
    /// When bytes last moved — used to end a run that has gone silent.
    private var lastProgressAt = Date()
    /// False when this run is a copy: the Mac gets the files, the phone
    /// keeps them.
    private var removeFromPhone = true
    private static let removeFromPhoneKey = "offload.removeFromPhone"

    // Per-run bookkeeping (main actor).
    /// Mirrors `isBusy` so the UI updates without every call site changing.
    private var isRunning: Bool {
        get { isBusy }
        set { isBusy = newValue }
    }
    private var totalFiles = 0
    private var completedFiles = 0
    private var failedFiles = 0
    private var offloadedBytes: Int64 = 0
    private var clipsCleared = 0
    /// clip UUID → file kinds still awaiting verification.
    private var pendingKinds: [UUID: Set<String>] = [:]

    static var backgroundCompletionHandler: (() -> Void)?

    init(settings: AppSettings, storage: StorageManager, tagStore: TagStore, modelContext: ModelContext) {
        self.settings = settings
        self.storage = storage
        self.tagStore = tagStore
        self.modelContext = modelContext
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.cjcombs.dashcam.offload")
        config.isDiscretionary = false
        config.allowsCellularAccess = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Discovery

    /// Brings the link to DashCam Studio up or down. Nothing is ever
    /// uploaded on its own — the connection only makes the Mac reachable so
    /// you can send clips when you choose to.
    func applyConnectionSetting() {
        settings.studioConnectionEnabled ? startBrowsing() : stopBrowsing()
    }

    func startBrowsing() {
        guard browser == nil else { return }
        status = .searching
        let browser = NWBrowser(
            for: .bonjour(type: "_dashcam-offload._tcp", domain: nil),
            using: NWParameters.tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleBrowseResults(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Drops the link. Any transfer in flight is cancelled — switching the
    /// connection off should mean off.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolveConnection?.cancel()
        resolveConnection = nil
        baseURL = nil
        helperFound = false
        if isRunning { cancelOffload() }
        bannerResetTask?.cancel()
        bannerResetTask = nil
        status = .idle
        DiagLog.shared.info("Offload: connection to DashCam Studio switched off")
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        guard let first = results.first else {
            helperFound = false
            baseURL = nil
            if !isRunning { status = .searching }
            return
        }
        guard baseURL == nil, resolveConnection == nil else { return }
        resolve(first.endpoint)
    }

    /// Bonjour gives a service endpoint; connect once to learn the concrete
    /// host/port for HTTP URLs.
    private func resolve(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolveConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case let .hostPort(host, port) = remote {
                        self.confirmHelper(host: host, port: port)
                    }
                    connection.cancel()
                    self.resolveConnection = nil
                case .failed, .cancelled:
                    self.resolveConnection = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func confirmHelper(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let hostText: String
        switch host {
        case .ipv4(let address):
            hostText = "\(address)"
        case .ipv6(let address):
            hostText = "[\(String(describing: address).replacingOccurrences(of: "%", with: "%25"))]"
        case .name(let name, _):
            hostText = name
        @unknown default:
            return
        }
        guard let url = URL(string: "http://\(hostText):\(port.rawValue)") else { return }

        Task { @MainActor in
            var request = URLRequest(url: url.appendingPathComponent("ping"))
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                self.baseURL = url
                self.helperFound = true
                self.helperName = hostText
                if !self.isRunning { self.status = .ready(hostText) }
                DiagLog.shared.info("Offload helper found at \(hostText):\(port.rawValue)")
                // Tag data labelled on the Mac arrives on its own — no
                // button press needed.
                await self.autoImportRoadMemory()
            } catch {
                DiagLog.shared.error("Offload helper ping failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Road memory import (labelled on the Mac, recalled on the road)

    /// One feature as exported by DashCam Studio.
    private struct FeatureImport: Decodable {
        var type: String
        var value: String?
        var latitude: Double
        var longitude: Double
        var heading: Double
        var source: String?
    }

    private struct MemoryImport: Decodable {
        var version: Int
        var features: [FeatureImport]
    }

    /// Silent version run whenever the Mac is discovered: pulls anything new
    /// and only speaks up if something actually arrived.
    private func autoImportRoadMemory() async {
        let before = roadMemory?.allFeatures().count ?? 0
        await importRoadMemory(announceQuietly: true)
        let after = roadMemory?.allFeatures().count ?? 0
        if after > before {
            importMessage = "Received \(after - before) road feature(s) labelled on your Mac."
        }
    }

    /// Pulls the road-memory file the Mac produced from labelled clips and
    /// merges it into local memory. Imported features are authoritative —
    /// you drew them by hand — so they arrive as manual entries.
    /// Pushes every removal the driver has made to DashCam Studio, so the
    /// Mac stops exporting those signs at source. Runs before an import —
    /// otherwise the Mac would hand back exactly what was just removed.
    ///
    /// - Returns: how many tombstones the Mac accepted.
    @discardableResult
    func syncForgottenFeatures() async -> Int {
        guard let baseURL, let memory = roadMemory else { return 0 }
        let pending = memory.tombstones().filter { !$0.syncedToDesktop }
        guard !pending.isEmpty else { return 0 }

        let payload = pending.compactMap { tombstone -> ForgottenFeatureExport? in
            guard let type = tombstone.type else { return nil }
            return ForgottenFeatureExport(
                type: type.rawValue,
                latitude: tombstone.latitude,
                longitude: tombstone.longitude,
                heading: tombstone.heading,
                forgottenAt: tombstone.createdAt
            )
        }
        guard !payload.isEmpty else { return 0 }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("forget"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                DiagLog.shared.error("Forget sync: the Mac rejected \(payload.count) removal(s)")
                return 0
            }
            memory.markTombstonesSynced(pending)
            DiagLog.shared.info("Forget sync: \(payload.count) removal(s) accepted by Studio")
            return payload.count
        } catch {
            DiagLog.shared.error("Forget sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Reports the outcome of an import back to DashCam Studio, so the
    /// training console can show what the phone accepted rather than what
    /// the Mac hoped it would.
    private func sendSyncReport(
        imported: Int, alreadyKnown: Int, refusedForgotten: Int, unsupported: Int
    ) async {
        guard let baseURL, let memory = roadMemory else { return }
        let report = PhoneSyncReport(
            at: Date(),
            deviceName: UIDevice.current.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            featuresHeld: memory.allFeatures().count,
            imported: imported,
            skippedAlreadyKnown: alreadyKnown,
            refusedForgotten: refusedForgotten,
            unsupported: unsupported,
            tombstones: memory.tombstones().count
        )
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("sync-report"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(report)
            _ = try await URLSession.shared.data(for: request)
            DiagLog.shared.info("Sync report sent: \(imported) imported, \(report.featuresHeld) held")
        } catch {
            DiagLog.shared.error("Sync report failed: \(error.localizedDescription)")
        }
    }

    func importRoadMemory(announceQuietly: Bool = false) async {
        guard let baseURL else {
            if !announceQuietly { importMessage = "Mac helper not found on this network." }
            return
        }
        guard let memory = roadMemory else { return }
        // Push removals first, or the Mac hands straight back what was just
        // taken out.
        await syncForgottenFeatures()

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("memory"))
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                if !announceQuietly { importMessage = "No response from the Mac." }
                return
            }
            guard http.statusCode == 200 else {
                if !announceQuietly { importMessage = "The Mac hasn't exported any road memory yet." }
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(MemoryImport.self, from: data)

            var added = 0
            var skipped = 0
            var refusedForgotten = 0
            var unsupported = 0
            for feature in payload.features {
                guard let type = RoadFeatureType(rawValue: feature.type) else {
                    skipped += 1
                    unsupported += 1
                    continue
                }
                // Never resurrect a sign that was removed on the phone.
                if memory.isBuried(
                    type: type, latitude: feature.latitude,
                    longitude: feature.longitude, heading: feature.heading
                ) {
                    skipped += 1
                    refusedForgotten += 1
                    continue
                }
                // Don't duplicate what's already known at that spot.
                let alreadyKnown = memory.allFeatures().contains { existing in
                    existing.type == type && GeoMatch.isSameFeature(
                        existingLat: existing.latitude, existingLon: existing.longitude,
                        existingHeading: existing.heading,
                        newLat: feature.latitude, newLon: feature.longitude,
                        newHeading: feature.heading
                    )
                }
                if alreadyKnown {
                    skipped += 1
                    continue
                }
                memory.addManual(
                    type: type, value: feature.value,
                    latitude: feature.latitude, longitude: feature.longitude,
                    heading: feature.heading
                )
                added += 1
            }

            importMessage = "Imported \(added) feature(s) from your Mac."
                + (skipped > 0 ? " \(skipped) already known or unsupported." : "")
            DiagLog.shared.info("Memory import: \(added) added, \(skipped) skipped")

            // Tell the Mac what actually happened. Without this the training
            // loop is one-way and unverifiable — Studio could claim it sent
            // 40 corrections with no way to know the phone took any.
            await sendSyncReport(
                imported: added,
                alreadyKnown: max(0, skipped - refusedForgotten - unsupported),
                refusedForgotten: refusedForgotten,
                unsupported: unsupported
            )
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
            DiagLog.shared.error("Memory import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Offload run

    /// Offloads everything the phone is holding.
    func startOffload() {
        let clips = (try? modelContext.fetch(FetchDescriptor<ClipSegment>())) ?? []
        startOffload(clips: clips)
    }

    /// Offloads only the clips handed in — how the Library's "Offload"
    /// button moves a chosen few without filling the Mac's disk.
    ///
    /// - Parameter removeFromPhone: the default, and how offloading has
    ///   always worked: once the Mac verifies a clip's checksum the phone's
    ///   copy is deleted. Pass `false` to send a copy and keep the original,
    ///   which is what "Send to Studio" does from the player — a clip you're
    ///   watching should not disappear underneath you.
    func startOffload(clips: [ClipSegment], removeFromPhone: Bool = true) {
        self.removeFromPhone = removeFromPhone
        // Survives a relaunch: a resumed run must not delete files the owner
        // asked to keep, nor keep files a full offload meant to reclaim.
        UserDefaults.standard.set(removeFromPhone, forKey: Self.removeFromPhoneKey)
        guard !isRunning, let baseURL else { return }
        guard !isRecordingProvider() else {
            status = .failed("Stop recording before offloading.")
            scheduleBannerReset()
            return
        }

        guard !clips.isEmpty else {
            status = .finished(clips: 0, bytes: 0)
            scheduleBannerReset()
            return
        }

        bannerResetTask?.cancel()
        bannerResetTask = nil
        lastProgressAt = Date()
        isRunning = true
        totalFiles = 0
        completedFiles = 0
        failedFiles = 0
        offloadedBytes = 0
        clipsCleared = 0
        pendingKinds = [:]
        activeUploads = []

        DiagLog.shared.info("Offload starting: \(clips.count) clips → \(baseURL.absoluteString)")
        status = .offloading(done: 0, total: clips.count)
        startWatchdog()

        // Hash + enqueue off the main actor; uploads then run in the
        // background session even if the phone gets locked.
        let uploadBase = baseURL
        let items: [(clipID: UUID, kind: String, url: URL, fileName: String)] = clips.flatMap { clip -> [(UUID, String, URL, String)] in
            var files: [(UUID, String, URL, String)] = [
                (clip.id, "video", storage.url(forFileName: clip.fileName, in: clip.folder), clip.fileName)
            ]
            if let sidecarName = clip.sidecarFileName {
                let sidecarURL = storage.url(forFileName: sidecarName, in: clip.folder)
                if FileManager.default.fileExists(atPath: sidecarURL.path) {
                    files.append((clip.id, "sidecar", sidecarURL, sidecarName))
                }
            }
            return files
        }
        for item in items {
            pendingKinds[item.clipID, default: []].insert(item.kind)
        }
        totalFiles = items.count

        Task.detached(priority: .userInitiated) { [session] in
            for item in items {
                guard FileManager.default.fileExists(atPath: item.url.path),
                      let hash = try? Self.sha256(of: item.url) else {
                    // Must still be accounted for, or the run can never
                    // reach its total and hangs at "17/20" forever.
                    await MainActor.run {
                        DiagLog.shared.error("Offload: cannot read \(item.fileName); skipping")
                        self.itemSkipped(clipID: item.clipID, fileName: item.fileName)
                    }
                    continue
                }
                var request = URLRequest(url: uploadBase.appendingPathComponent("upload"))
                request.httpMethod = "POST"
                request.setValue(item.fileName, forHTTPHeaderField: "X-File-Name")
                request.setValue(hash, forHTTPHeaderField: "X-SHA256")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let task = session!.uploadTask(with: request, fromFile: item.url)
                task.taskDescription = "\(item.clipID.uuidString)|\(item.kind)|\(item.fileName)"
                task.resume()
            }
        }
    }

    /// A file that could never be enqueued (missing or unreadable). Counted
    /// as done-with-failure so the run can still complete.
    private func itemSkipped(clipID: UUID, fileName: String) {
        guard isRunning else { return }
        completedFiles += 1
        failedFiles += 1
        pendingKinds.removeValue(forKey: clipID) // never delete a partial clip
        if completedFiles >= totalFiles {
            finishRun()
        } else {
            status = .offloading(done: completedFiles, total: totalFiles)
        }
    }

    // MARK: - Resume after a crash, force-quit, or interrupted transfer

    /// Adopts any uploads the background session is still carrying from a
    /// previous launch, so an interrupted run continues instead of stalling.
    func resumeIfNeeded() async {
        guard !isRunning else { return }

        // First launch after auto-offload was forced off: drop whatever that
        // run had already queued instead of picking it back up.
        if settings.didJustDisableAutoOffload {
            let stale = await session.allTasks
            stale.forEach { $0.cancel() }
            isRunning = false
            activeUploads = []
            pendingKinds = [:]
            if !stale.isEmpty {
                DiagLog.shared.info("Offload: auto-offload disabled — cancelled \(stale.count) queued upload(s)")
            }
            return
        }

        let tasks = await session.allTasks
        let live = tasks.filter { $0.state == .running || $0.state == .suspended }
        guard !live.isEmpty else {
            await reconcileStragglers()
            return
        }

        bannerResetTask?.cancel()
        bannerResetTask = nil
        lastProgressAt = Date()
        removeFromPhone = UserDefaults.standard.object(forKey: Self.removeFromPhoneKey) as? Bool ?? true
        isRunning = true
        totalFiles = live.count
        completedFiles = 0
        failedFiles = 0
        offloadedBytes = 0
        clipsCleared = 0
        pendingKinds = [:]
        activeUploads = []

        for task in live {
            guard let description = task.taskDescription else { continue }
            let parts = description.components(separatedBy: "|")
            guard parts.count == 3, let clipID = UUID(uuidString: parts[0]) else { continue }
            pendingKinds[clipID, default: []].insert(parts[1])
            if task.state == .suspended { task.resume() }
        }

        status = .offloading(done: 0, total: totalFiles)
        DiagLog.shared.info("Offload: resumed \(live.count) in-flight upload(s) after relaunch")
        startWatchdog()
    }

    /// Nothing in flight but the phone still holds clips — clear any stale
    /// running state so the next attempt isn't blocked.
    private func reconcileStragglers() async {
        if isRunning {
            DiagLog.shared.error("Offload: no live tasks but run was marked active — clearing")
            finishRun()
        }
    }

    /// If a run stops making progress and the session has nothing left, end
    /// it rather than sitting at "17/20" indefinitely.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                let tasks = await self.session.allTasks
                let live = tasks.filter { $0.state == .running || $0.state == .suspended }
                if live.isEmpty {
                    DiagLog.shared.error(
                        "Offload: watchdog found no live uploads at \(self.completedFiles)/\(self.totalFiles) — ending run"
                    )
                    self.finishRun()
                } else if Date().timeIntervalSince(self.lastProgressAt) > 120 {
                    // Tasks exist but no bytes have moved for two minutes —
                    // the Mac went away mid-transfer. End it rather than
                    // leaving the banner up forever.
                    DiagLog.shared.error(
                        "Offload: no progress for 120 s at \(self.completedFiles)/\(self.totalFiles) — ending run"
                    )
                    live.forEach { $0.cancel() }
                    self.failedFiles += max(0, self.totalFiles - self.completedFiles)
                    self.finishRun()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Manual escape hatch: stop everything and allow a fresh attempt.
    func cancelOffload() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        watchdog?.invalidate()
        watchdog = nil
        activeUploads = []
        pendingKinds = [:]
        isRunning = false
        status = .failed("Offload cancelled. Tap Offload now to try again.")
        lastRunSummary = "Cancelled"
        scheduleBannerReset()
        DiagLog.shared.info("Offload: cancelled by user")
    }

    /// A finished or cancelled run leaves its banner up for a few seconds so
    /// the outcome is readable, then the app goes back to "ready" — the
    /// driving screen must never keep a stale bar across the view.
    private func scheduleBannerReset(after seconds: Double = 10) {
        bannerResetTask?.cancel()
        bannerResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.status = self.helperFound
                ? .ready(self.helperName ?? "Mac")
                : (self.browser == nil ? .idle : .searching)
        }
    }

    /// Byte-level progress for one in-flight file.
    private func taskProgressed(description: String?, sent: Int64, total: Int64) {
        guard isRunning, let description else { return }
        let parts = description.components(separatedBy: "|")
        guard parts.count == 3 else { return }
        let fileName = parts[2]
        lastProgressAt = Date()

        if let index = activeUploads.firstIndex(where: { $0.id == description }) {
            activeUploads[index].bytesSent = sent
            activeUploads[index].totalBytes = total
        } else {
            activeUploads.append(UploadProgress(
                id: description, fileName: fileName, bytesSent: sent, totalBytes: total
            ))
        }
    }

    private func taskFinished(description: String?, ok: Bool, bytes: Int64) {
        guard let description else { return }
        guard isRunning else {
            // A task that finished while the app was closed. Don't delete
            // anything without full accounting — the next run reconciles.
            DiagLog.shared.info("Offload: late completion for \(description); will reconcile next run")
            return
        }
        activeUploads.removeAll { $0.id == description }
        lastProgressAt = Date()
        let parts = description.components(separatedBy: "|")
        guard parts.count == 3, let clipID = UUID(uuidString: parts[0]) else { return }
        let kind = parts[1]
        let fileName = parts[2]

        completedFiles += 1
        if ok {
            offloadedBytes += bytes
            pendingKinds[clipID]?.remove(kind)
            if pendingKinds[clipID]?.isEmpty == true {
                pendingKinds.removeValue(forKey: clipID)
                if removeFromPhone {
                    clearClip(id: clipID)
                } else {
                    clipsCleared += 1   // counted as delivered, not deleted
                }
            }
        } else {
            failedFiles += 1
            pendingKinds.removeValue(forKey: clipID) // don't delete a partial clip
            DiagLog.shared.error("Offload: \(fileName) was not verified by the Mac; keeping it on the phone")
        }

        if completedFiles >= totalFiles {
            finishRun()
        } else {
            status = .offloading(done: completedFiles, total: totalFiles)
        }
    }

    private func clearClip(id: UUID) {
        let descriptor = FetchDescriptor<ClipSegment>(predicate: #Predicate { $0.id == id })
        guard let clip = try? modelContext.fetch(descriptor).first else { return }
        try? tagStore.delete(clip, context: modelContext)
        clipsCleared += 1
    }

    private func finishRun() {
        isRunning = false
        activeUploads = []
        watchdog?.invalidate()
        watchdog = nil
        if failedFiles > 0 {
            status = .failed("\(failedFiles) file(s) failed verification and stayed on the phone.")
            lastRunSummary = "\(clipsCleared) clip(s) moved, \(failedFiles) kept back"
        } else {
            status = .finished(clips: clipsCleared, bytes: offloadedBytes)
            lastRunWasCopy = !removeFromPhone
            lastRunSummary = clipsCleared > 0
                ? "\(clipsCleared) clip(s), \(Format.fileSize(offloadedBytes))"
                    + (removeFromPhone ? "" : " (copies kept)")
                : "Nothing to offload"
        }
        scheduleBannerReset()
        DiagLog.shared.info(
            "Offload finished: \(clipsCleared) clips cleared, \(offloadedBytes) bytes moved, \(failedFiles) failures"
        )
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSession delegate (background session)

extension OffloadService: URLSessionTaskDelegate, URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let description = task.taskDescription
        Task { @MainActor in
            self.taskProgressed(
                description: description,
                sent: totalBytesSent,
                total: totalBytesExpectedToSend
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ok = error == nil && (task.response as? HTTPURLResponse)?.statusCode == 200
        let bytes = task.countOfBytesSent
        let description = task.taskDescription
        Task { @MainActor in
            self.taskFinished(description: description, ok: ok, bytes: bytes)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            OffloadService.backgroundCompletionHandler?()
            OffloadService.backgroundCompletionHandler = nil
        }
    }
}
