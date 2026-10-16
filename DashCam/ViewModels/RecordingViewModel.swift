import Combine
import Foundation
import SwiftData
import UIKit

/// Coordinates the recording screen: session state, HUD dimming, tagging,
/// storage warnings, thermal/interruption banners, and segment finalization.
@MainActor
final class RecordingViewModel: ObservableObject {
    enum ScreenMode {
        case full
        case hud
    }

    // MARK: - Dependencies

    let settings: AppSettings
    let capture: CaptureService
    let location: LocationService
    let motion: MotionService
    let storage: StorageManager
    let tagStore: TagStore
    /// Set by the app after init; source of signal state for gating/evidence.
    weak var roadScene: RoadScene?
    private let telemetry = TelemetryRecorder()
    private let modelContext: ModelContext

    // MARK: - Published state

    @Published var screenMode: ScreenMode = .full
    @Published var showStartupModal = false
    @Published private(set) var acknowledged = false
    @Published var tagFlash = false
    @Published private(set) var lowLoopCapacity = false
    @Published var storageFullAlert = false
    /// Raised when a finished segment's sidecar came back without the replay
    /// data it should hold. Surfaced on the recording screen so a drive that
    /// isn't capturing overlays is caught on the road, not weeks later.
    @Published var telemetryWarning: String?
    /// Non-nil while recording is halted by an interruption; shown with Resume.
    @Published var interruptionMessage: String?
    @Published var showLibrary = false
    @Published var showSettings = false
    /// Fused gyro heading fallback, refreshed at 1 Hz for the overlay/HUD.
    @Published private(set) var motionHeading: Double?
    /// Live ride-roughness (g) and thermal state for the telemetry box.
    @Published private(set) var vibrationG: Double?
    @Published private(set) var thermalRaw: String?
    /// Shown when the user asks for Always location but iOS can't re-prompt.
    @Published var showLocationSettingsAlert = false

    // MARK: - Session bookkeeping

    private var sessionLog: SessionLog?
    private var currentSegmentFileName: String?
    private var currentSegmentStartedAt: Date?
    private var pendingTagsByFile: [String: [PendingTag]] = [:]
    private var samplesByFile: [String: [TelemetrySample]] = [:]
    /// Green-box detections per in-flight segment, saved into its sidecar so
    /// playback can replay them.
    private var emergencyEventsByFile: [String: [EmergencyEvent]] = [:]
    /// Signal display changes per in-flight segment (incident evidence).
    private var signalEventsByFile: [String: [SignalEvent]] = [:]
    /// ~2 Hz snapshots of the whole on-screen overlay state, so replay and
    /// full-graphical exports match the live view exactly.
    private var overlaySnapshotsByFile: [String: [OverlaySnapshot]] = [:]
    private var lastSnapshotAt: Double = -1
    /// Speed-gated signal display: shown when slowing/stopped, hidden while
    /// cruising — the sidecar still records everything.
    @Published private(set) var signalGateOpen = true
    private var lastGateMph: Double = 0
    /// Read from the capture output queue during preflight; lock-protected.
    private let segmentNaming = SegmentNaming()
    private var lastInteraction = Date()
    private var previousBrightness: CGFloat?
    private var hudTimer: Timer?
    private var bootstrapped = false
    private var wasShutDown = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: AppSettings,
        capture: CaptureService,
        location: LocationService,
        motion: MotionService,
        storage: StorageManager,
        tagStore: TagStore,
        modelContext: ModelContext
    ) {
        self.settings = settings
        self.capture = capture
        self.location = location
        self.motion = motion
        self.storage = storage
        self.tagStore = tagStore
        self.modelContext = modelContext
    }

    var isRecording: Bool { capture.isRecording }
    /// Night styling engages from the manual day/night switch or automatic
    /// ISO-based detection.
    var isNight: Bool { settings.nightScreenMode || capture.isNightConditions }
    /// True when Always location is wanted but not (yet) granted.
    var locationNotAlways: Bool {
        settings.alwaysLocation && location.authorizationStatus != .authorizedAlways
    }

    // MARK: - Bootstrap (once per launch)

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        try? storage.ensureFolders()

        let log = SessionLog(launchedAt: Date(), resolution: settings.resolution)
        modelContext.insert(log)
        try? modelContext.save()
        sessionLog = log

        if settings.showStartupReminder {
            showStartupModal = true
        } else {
            acknowledged = true
        }

        wireCallbacks()
        location.headingFallback = { [weak motion] in motion?.currentHeading }
        location.start()
        motion.startMonitoring()
        reconfigureCapture()
        refreshCapacityWarning()
        startHUDTimer()

        // Republish nested service changes so views observing this model update.
        capture.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        location.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Record every signal display change into the segment's sidecar —
        // if there's a crash, the recording proves what the light was.
        roadScene?.$signal
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.capture.isRecording,
                      let fileName = self.currentSegmentFileName else { return }
                let offset = self.capture.currentSegmentElapsed() ?? 0
                let stateName = state.map { String(describing: $0) } ?? "none"
                self.signalEventsByFile[fileName, default: []].append(
                    SignalEvent(offset: offset, state: stateName)
                )
            }
            .store(in: &cancellables)

        // Record green-box detections into the segment's sidecar (~2 Hz max)
        // so the box can be replayed during playback.
        capture.$emergencyDetection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detection in
                guard let self, let detection,
                      self.capture.isRecording,
                      let fileName = self.currentSegmentFileName else { return }
                let offset = self.capture.currentSegmentElapsed() ?? 0
                var events = self.emergencyEventsByFile[fileName, default: []]
                if let last = events.last, offset - last.offset < 0.4 { return }
                events.append(EmergencyEvent(
                    offset: offset,
                    x: detection.box.origin.x,
                    y: detection.box.origin.y,
                    width: detection.box.width,
                    height: detection.box.height
                ))
                self.emergencyEventsByFile[fileName] = events
            }
            .store(in: &cancellables)
    }

    // MARK: - App lifecycle (clean reset on close)

    /// Leaving the app is a full shutdown: recording finalizes, every service
    /// stops, and the next activation behaves like a fresh launch — startup
    /// checklist included.
    func appEnteredBackground() {
        guard bootstrapped else { return }
        if capture.isRecording {
            stopRecording()
        }
        capture.stopSession()
        location.stop()
        motion.stopMonitoring()
        exitHUD()
        showLibrary = false
        showSettings = false
        interruptionMessage = nil
        storageFullAlert = false
        acknowledged = false
        wasShutDown = true
        DiagLog.shared.info("App backgrounded — services shut down (clean reset)")
    }

    /// Fresh start on return: new session log, startup checklist, services up.
    func appBecameActive() {
        guard bootstrapped, wasShutDown else { return }
        wasShutDown = false

        let log = SessionLog(launchedAt: Date(), resolution: settings.resolution)
        modelContext.insert(log)
        try? modelContext.save()
        sessionLog = log

        if settings.showStartupReminder {
            showStartupModal = true
            acknowledged = false
        } else {
            acknowledged = true
        }

        location.start()
        motion.startMonitoring()
        reconfigureCapture()
        refreshCapacityWarning()
        DiagLog.shared.info("App reactivated — fresh session started")
    }

    func acknowledgeStartup() {
        sessionLog?.acknowledgedAt = Date()
        try? modelContext.save()
        acknowledged = true
        showStartupModal = false
        // Upgrade to Always once the checklist is out of the way; iOS shows
        // its own prompt if the upgrade is still available.
        if locationNotAlways {
            location.requestAlwaysAuthorization()
        }
    }

    // MARK: - Settings changes (only take effect while stopped)

    private func reconfigureCapture() {
        capture.configureAndStart(
            resolution: settings.resolution,
            audioEnabled: settings.audioEnabled,
            camera: settings.camera
        )
    }

    func resolutionChanged() {
        guard !capture.isRecording else { return }
        reconfigureCapture()
        refreshCapacityWarning()
    }

    func audioSettingChanged() {
        guard !capture.isRecording else { return }
        reconfigureCapture()
    }

    func cameraChanged() {
        guard !capture.isRecording else { return }
        reconfigureCapture()
    }

    /// While the library is open and nothing is recording, stop the camera
    /// session so clip playback has the media pipeline to itself.
    func libraryVisibilityChanged(isOpen: Bool) {
        sheetVisibilityChanged(isOpen: isOpen)
        guard !capture.isRecording else { return }
        if isOpen {
            capture.stopSession()
        } else {
            reconfigureCapture()
        }
    }

    /// Common bookkeeping for any sheet: restore brightness if the HUD was
    /// active, and reset the inactivity clock when the sheet closes.
    func sheetVisibilityChanged(isOpen: Bool) {
        if isOpen, screenMode == .hud {
            exitHUD()
        }
        if !isOpen {
            noteInteraction()
        }
    }

    /// Settings toggle handler: try the system Always upgrade; if iOS won't
    /// re-prompt (already asked once), point the user at the Settings app.
    func requestAlwaysLocation() {
        guard location.authorizationStatus != .authorizedAlways else { return }
        location.requestAlwaysAuthorization()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.settings.alwaysLocation,
               self.location.authorizationStatus != .authorizedAlways {
                self.showLocationSettingsAlert = true
            }
        }
    }

    // MARK: - Recording control

    func toggleRecording() {
        if capture.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard acknowledged, capture.cameraAvailable, !capture.isRecording else { return }
        interruptionMessage = nil
        segmentNaming.reset(segmentLength: settings.segmentLength)
        pendingTagsByFile.removeAll()
        samplesByFile.removeAll()
        emergencyEventsByFile.removeAll()
        signalEventsByFile.removeAll()
        overlaySnapshotsByFile.removeAll()
        lastSnapshotAt = -1
        currentSegmentFileName = nil
        currentSegmentStartedAt = nil

        telemetry.sampleProvider = { [weak self] in
            guard let self else { return TelemetrySample(timestamp: Date()) }
            var sample = self.location.currentSample()
            sample.vibrationG = self.motion.currentVibrationG
            sample.thermal = Format.thermalRaw(ProcessInfo.processInfo.thermalState)
            return sample
        }
        // File every sample against the segment that's recording as it is
        // taken. Nothing waits to be claimed later, so a segment finalising
        // before the next one starts can no longer strand its telemetry.
        telemetry.onSample = { [weak self] sample in
            guard let self, let fileName = self.currentSegmentFileName else { return }
            self.samplesByFile[fileName, default: []].append(sample)
        }
        motion.updateSensitivity(settings.sensitivity)
        motion.setDetecting(true)
        UIApplication.shared.isIdleTimerDisabled = true
        noteInteraction()

        // Freeze the interface in its current orientation for the whole
        // session; recording must stop before the view can rotate again.
        let orientation = currentInterfaceOrientation()
        AppDelegate.apply(Self.orientationMask(for: orientation))

        DiagLog.shared.info(
            "Recording started — \(settings.resolution.label), \(settings.camera.label) camera, \(Int(settings.segmentLength))s segments, audio \(settings.audioEnabled ? "on" : "off")"
        )
        capture.startRecording(
            segmentLength: settings.segmentLength,
            transform: Self.videoTransform(for: orientation)
        )
    }

    func stopRecording() {
        capture.stopRecording()
        finishRecordingHousekeeping()
    }

    private func finishRecordingHousekeeping() {
        motion.setDetecting(false)
        UIApplication.shared.isIdleTimerDisabled = false
        AppDelegate.apply(.landscape)
        telemetry.end()
        currentSegmentFileName = nil
        currentSegmentStartedAt = nil
        exitHUD()
    }

    func resumeAfterInterruption() {
        interruptionMessage = nil
        reconfigureCapture()
        startRecording()
    }

    // MARK: - Tagging

    func tag(source: TagSource) {
        guard capture.isRecording,
              let fileName = currentSegmentFileName,
              let startedAt = currentSegmentStartedAt else { return }
        let now = Date()
        let sample = location.currentSample()
        // Prefer the segment's media-time clock so the tag lands exactly on
        // the video timeline; wall clock is only a fallback.
        let offset = capture.currentSegmentElapsed() ?? max(0, now.timeIntervalSince(startedAt))
        let pending = PendingTag(
            timestamp: now,
            offsetInClip: offset,
            latitude: sample.latitude,
            longitude: sample.longitude,
            speedMPS: sample.speedMPS,
            source: source
        )
        pendingTagsByFile[fileName, default: []].append(pending)

        Haptics.tagConfirmed()
        tagFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.tagFlash = false
        }
    }

    // MARK: - HUD dimming

    func noteInteraction() {
        lastInteraction = Date()
        if screenMode == .hud {
            exitHUD()
        }
    }

    private func startHUDTimer() {
        hudTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hudTimerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    private func hudTimerTick() {
        motionHeading = motion.currentHeading
        vibrationG = motion.currentVibrationG
        thermalRaw = Format.thermalRaw(ProcessInfo.processInfo.thermalState)

        // Signal display gate: open when slowing or below ~20 mph, closed
        // above ~25 mph (hysteresis so it doesn't flicker at the boundary).
        let mph = max(0, location.speedMPS) * 2.23694
        let slowingHard = lastGateMph - mph >= 3
        if signalGateOpen {
            if mph > 25 { signalGateOpen = false }
        } else if mph < 20 || slowingHard {
            signalGateOpen = true
        }
        lastGateMph = mph
        captureOverlaySnapshot()

        // Self-heal: if we're on the full screen but a stored brightness was
        // never restored (any interrupted dim path), restore it now so the
        // display can never stay stuck dark.
        if screenMode == .full, let stored = previousBrightness {
            UIScreen.main.brightness = stored
            previousBrightness = nil
        }

        // Never auto-dim under a presented sheet: dropping the hardware
        // brightness would black out the sheet with no way to tap back.
        guard capture.isRecording, screenMode == .full,
              !showLibrary, !showSettings, !showStartupModal else { return }
        if Date().timeIntervalSince(lastInteraction) >= settings.hudDimDelay {
            enterHUD()
        }
    }

    /// Records what the screen is showing (~2 Hz) into the current segment,
    /// so replay and full-graphical exports match the live view exactly.
    private func captureOverlaySnapshot() {
        guard capture.isRecording,
              let fileName = currentSegmentFileName,
              let scene = roadScene,
              let offset = capture.currentSegmentElapsed(),
              offset - lastSnapshotAt >= 0.5 else { return }
        lastSnapshotAt = offset

        let snapshot = OverlaySnapshot(
            offset: offset,
            speedLimit: scene.speedLimit,
            humpShowing: scene.humpUntil != nil,
            humpSpeed: scene.humpSpeed,
            schoolShowing: scene.schoolUntil != nil,
            schoolSpeed: scene.schoolSpeed,
            hospitalShowing: scene.hospitalUntil != nil,
            bikeShowing: scene.bikeUntil != nil,
            cityName: scene.cityUntil != nil ? scene.cityName : nil,
            fireStation: scene.fireStationUntil != nil ? scene.fireStationLabel : nil,
            signal: signalGateOpen ? scene.signal.map { String(describing: $0) } : nil,
            cyclist: scene.cyclist.map { $0.direction == .right ? "right" : "left" },
            pedestrians: scene.pedestrianBoxes.isEmpty
                ? nil
                : scene.pedestrianBoxes.map { [$0.minX, $0.minY, $0.width, $0.height] }
        )
        overlaySnapshotsByFile[fileName, default: []].append(snapshot)
    }

    /// On-demand dim (the small DIM button); same HUD as the auto timeout.
    func dimNow() {
        enterHUD()
    }

    /// Manual day/night switch: day pushes the screen to 90% brightness,
    /// night drops it very low and engages the night palette.
    func toggleDayNight() {
        settings.nightScreenMode.toggle()
        UIScreen.main.brightness = settings.nightScreenMode ? 0.08 : 0.9
    }

    private func enterHUD() {
        guard screenMode == .full else { return }
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = isNight ? 0.02 : 0.08
        screenMode = .hud
    }

    func exitHUD() {
        if let brightness = previousBrightness {
            UIScreen.main.brightness = brightness
            previousBrightness = nil
        }
        screenMode = .full
        lastInteraction = Date()
    }

    // MARK: - Capture callbacks

    private func wireCallbacks() {
        // Runs on the capture output queue: preflight the storage budget and
        // hand back the next LOOP file URL, or nil to stop recording.
        let storage = self.storage
        let naming = self.segmentNaming
        capture.nextSegmentURL = { [weak self] resolution in
            let estimated = Int64(Double(resolution.estimatedBytesPerSecond) * naming.segmentLength)
            let result = try? storage.prepareForNextSegment(estimatedBytes: estimated)
            Task { @MainActor [weak self] in self?.refreshCapacityWarning() }
            if case .ready(let pruned) = result {
                if !pruned.isEmpty {
                    DiagLog.shared.info("Loop pruned \(pruned.count) segment(s): \(pruned.joined(separator: ", "))")
                }
                return storage.url(forFileName: naming.nextFileName(), in: .loop)
            }
            DiagLog.shared.error("Storage preflight refused next segment (result: \(String(describing: result)))")
            return nil
        }

        capture.onSegmentStarted = { [weak self] fileName, startedAt in
            guard let self else { return }
            self.currentSegmentFileName = fileName
            self.currentSegmentStartedAt = startedAt
            // Offsets restart at zero for every segment, so the snapshot
            // throttle has to restart with them. Left at the previous
            // segment's elapsed time it rejects every snapshot for the rest
            // of the drive.
            self.lastSnapshotAt = -1
            // Idempotent: keeps collecting across segment rotations and
            // across the thermal 4K→HD switch, which finalises a segment
            // mid-flight.
            self.telemetry.begin()
        }

        capture.onSegmentFinished = { [weak self] result in
            self?.handleSegmentFinished(result)
        }

        capture.onRecordingStopped = { [weak self] reason in
            guard let self else { return }
            self.finishRecordingHousekeeping()
            switch reason {
            case .storageFull:
                Haptics.failure()
                self.storageFullAlert = true
            case .interrupted(let message), .error(let message):
                Haptics.warning()
                self.interruptionMessage = message
            }
        }

        motion.onAutoTag = { [weak self] source in
            self?.tag(source: source)
        }

        capture.onEmergencyLights = { [weak self] in
            self?.tag(source: .emergencyLights)
        }
        capture.setEmergencyDetection(enabled: settings.emergencyLightDetection)
    }

    /// Reads back the sidecar that was just written and confirms the replay
    /// data is really in it. Anything missing is logged and raised on the
    /// recording screen while the drive is still happening.
    private func verifySidecar(named sidecarFileName: String?, segment: CaptureService.SegmentResult) {
        guard let sidecarFileName else {
            telemetryWarning = "Telemetry file could not be written"
            return
        }
        let url = storage.url(forFileName: sidecarFileName, in: .loop)
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? TelemetrySidecar.decoder().decode(TelemetrySidecar.self, from: data) else {
            DiagLog.shared.error("Telemetry: sidecar \(sidecarFileName) could not be read back after writing")
            telemetryWarning = "Telemetry file could not be read back"
            return
        }

        let verdict = TelemetryHealth.verdict(
            sampleCount: sidecar.samples.count,
            overlayCount: sidecar.overlaySnapshots?.count ?? 0,
            duration: segment.duration,
            detectionEnabled: settings.roadDetection
        )
        DiagLog.shared.info(
            "Telemetry check \(sidecarFileName): \(sidecar.samples.count) samples, "
            + "\(sidecar.overlaySnapshots?.count ?? 0) overlays over \(Int(segment.duration))s"
        )
        if let warning = verdict.warning {
            DiagLog.shared.error("Telemetry check FAILED for \(sidecarFileName): \(warning)")
            telemetryWarning = warning
        } else {
            telemetryWarning = nil
        }
    }

    private func handleSegmentFinished(_ result: CaptureService.SegmentResult) {
        // If this segment finished before its successor started, stop filing
        // telemetry against a bucket that's already been written out.
        if currentSegmentFileName == result.fileName {
            currentSegmentFileName = nil
        }
        let samples = samplesByFile.removeValue(forKey: result.fileName) ?? []
        let emergencyEvents = emergencyEventsByFile.removeValue(forKey: result.fileName) ?? []
        let signalEvents = signalEventsByFile.removeValue(forKey: result.fileName) ?? []
        let snapshots = overlaySnapshotsByFile.removeValue(forKey: result.fileName) ?? []
        telemetry.writeSidecar(
            samples: samples,
            emergencyEvents: emergencyEvents,
            signalEvents: signalEvents,
            overlaySnapshots: snapshots,
            segmentFileName: result.fileName,
            resolution: result.resolution,
            startedAt: result.startedAt,
            directory: storage.loopURL
        ) { [weak self] sidecarFileName in
            guard let self else { return }
            if sidecarFileName == nil {
                DiagLog.shared.error("Telemetry sidecar failed to write for \(result.fileName)")
            }
            // Prove the replay data reached the file. A clip that plays back
            // without its overlays is worthless as evidence, and the failure
            // is invisible until someone reviews the clip days later.
            self.verifySidecar(named: sidecarFileName, segment: result)
            let tags = self.pendingTagsByFile.removeValue(forKey: result.fileName) ?? []
            let clip = self.tagStore.registerSegment(
                result: result,
                sidecarFileName: sidecarFileName,
                pendingTags: tags,
                context: self.modelContext
            )
            self.refreshCapacityWarning()

            // Remux the finished segment (fragmented .mov → flat .mp4) in
            // the background so the player opens it instantly.
            SegmentOptimizer.shared.optimize(fileURL: self.tagStore.videoURL(for: clip)) { [weak self] result in
                guard let self, let result, result.bytes > 0 else { return }
                clip.fileName = result.fileName
                clip.fileSize = result.bytes
                clip.isOptimized = true
                try? self.modelContext.save()
            }
        }
    }

    // MARK: - Storage warnings

    func refreshCapacityWarning() {
        lowLoopCapacity = storage.isLoopCapacityLow(resolution: settings.resolution)
    }

    // MARK: - Helpers

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.interfaceOrientation ?? .landscapeRight
    }

    /// Back-camera buffers are sensor-native landscape-right; the transform
    /// only stamps display orientation metadata into the file.
    static func videoTransform(for orientation: UIInterfaceOrientation) -> CGAffineTransform {
        switch orientation {
        case .landscapeLeft: return CGAffineTransform(rotationAngle: .pi)
        case .portrait: return CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown: return CGAffineTransform(rotationAngle: -.pi / 2)
        default: return .identity
        }
    }

    static func orientationMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        // Landscape-only app: recording pins to the active landscape side.
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .landscape
        }
    }
}

/// Thread-safe segment naming shared between the main actor and the capture
/// output queue.
private final class SegmentNaming: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var length: Double = 180

    var segmentLength: Double {
        lock.lock()
        defer { lock.unlock() }
        return length
    }

    func reset(segmentLength: Double) {
        lock.lock()
        defer { lock.unlock() }
        counter = 0
        length = segmentLength
    }

    func nextFileName() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "DC_\(formatter.string(from: Date()))_\(String(format: "%03d", counter)).mov"
    }
}
