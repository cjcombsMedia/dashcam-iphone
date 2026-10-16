import AVFoundation
import Combine
import Foundation
import UIKit

/// User-selectable capture cameras. Availability varies by device model.
enum CameraSelection: String, CaseIterable, Identifiable, Codable {
    case wide
    case ultraWide
    case telephoto
    case front

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: return "Wide"
        case .ultraWide: return "Ultra Wide"
        case .telephoto: return "Telephoto"
        case .front: return "Front"
        }
    }

    var systemImage: String {
        switch self {
        case .wide: return "camera.fill"
        case .ultraWide: return "camera.metering.matrix"
        case .telephoto: return "camera.metering.spot"
        case .front: return "person.crop.square"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide, .front: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }
}

enum CaptureError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No back camera is available on this device."
        case .cannotAddInput: return "The camera input could not be added to the capture session."
        case .cannotAddOutput: return "The capture outputs could not be configured."
        }
    }
}

/// Segmented HEVC recorder built on AVCaptureSession + AVAssetWriter.
///
/// Writes QuickTime movie fragments every 2 seconds (movieFragmentInterval)
/// so an interruption never corrupts more than the last few seconds. Segments
/// rotate on the sample-buffer queue: the outgoing writer is finalized and the
/// incoming writer starts with the very next frame.
final class CaptureService: NSObject, ObservableObject {
    struct SegmentResult {
        var url: URL
        var fileName: String
        var startedAt: Date
        var duration: Double
        var resolution: VideoResolution
        var fileSize: Int64
        var isFinal: Bool
    }

    enum StopReason: Equatable {
        case storageFull
        case interrupted(String)
        case error(String)
    }

    // MARK: - Published UI state (main thread)

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    /// Ambient-light proxy from live ISO: drives the night HUD palette.
    @Published private(set) var isNightConditions = false
    @Published private(set) var thermalOverrideActive = false
    @Published private(set) var activeResolution: VideoResolution = .hd
    @Published private(set) var cameraAvailable = true
    /// Cameras present on this device, resolved at configure time.
    @Published private(set) var availableCameras: [CameraSelection] = [.wide]
    /// Live emergency-light detection for the green box overlay; nil when
    /// nothing is detected.
    @Published private(set) var emergencyDetection: EmergencyDetection?

    /// How focus is currently controlled.
    ///
    /// Default is `.auto`: continuous autofocus restricted to the FAR range.
    /// (Note: a locked lensPosition of 1.0 is NOT optical infinity — it's the
    /// mechanical far stop, which sits past infinity and leaves everything
    /// soft. Far-restricted continuous AF is Apple's intended way to keep
    /// distant scenes sharp without hunting onto near objects.)
    enum FocusControl: Equatable {
        case auto
        case tapped
        case manual(Float)
    }

    @Published private(set) var focusControl: FocusControl = .auto
    /// Current exposure bias (EV); 0 = neutral auto exposure.
    @Published private(set) var exposureBias: Float = 0

    var focusStatusText: String {
        switch focusControl {
        case .auto: return "Auto (far range)"
        case .tapped: return "Locked on tapped point"
        case .manual(let value): return String(format: "Manual %.2f", value)
        }
    }

    /// Called on the main queue when flashing emergency lights are confirmed
    /// (rate-limited by the detector's cooldown).
    var onEmergencyLights: (() -> Void)?

    // MARK: - Callbacks

    /// Called on the output queue before each segment starts; performs the
    /// storage preflight and returns the file URL, or nil to stop recording.
    var nextSegmentURL: ((VideoResolution) -> URL?)?
    /// Called on the main queue as each segment file finishes writing.
    var onSegmentFinished: ((SegmentResult) -> Void)?
    /// Called on the main queue when each segment begins, so telemetry is
    /// filed against the right segment from its first frame.
    var onSegmentStarted: ((String, Date) -> Void)?
    /// Called on the main queue when recording stops for a non-user reason.
    var onRecordingStopped: ((StopReason) -> Void)?

    // MARK: - Capture plumbing

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.cjcombs.dashcam.session")
    private let outputQueue = DispatchQueue(label: "com.cjcombs.dashcam.output", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var currentCamera: CameraSelection?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAttached = false
    private var isoObservation: NSKeyValueObservation?
    // Shadow copies of the published focus/exposure state, owned by the
    // session queue so configuration code never reads main-actor state.
    private var focusControlInternal: FocusControl = .auto
    private var exposureBiasInternal: Float = 0
    /// Media-time elapsed of the in-flight segment, readable from any thread.
    private let segmentClock = SegmentClock()

    // MARK: - Emergency light analysis (outputQueue + analyzerQueue)

    private let analyzerQueue = DispatchQueue(label: "com.cjcombs.dashcam.analyzer", qos: .utility)
    private var analyzerBusy = false        // outputQueue
    private var frameCounter = 0            // outputQueue
    private var emergencyEnabled = true     // outputQueue
    private var emergencyDetector = EmergencyLightDetector() // analyzerQueue

    /// Road-scene Vision tap (signs / humans), ~every 6th frame (5 Hz).
    var roadFrameSink: ((CVPixelBuffer, Double) -> Void)?
    /// Traffic-signal lamp tap, every 2nd frame (15 Hz) — lights are checked
    /// essentially continuously, fast enough for 75 mph.
    var roadLampSink: ((CVPixelBuffer, Double) -> Void)?
    /// Steady traffic-signal regions to exclude from emergency detection.
    var emergencyExclusionProvider: (() -> [CGRect])?

    // MARK: - Writer state (outputQueue only)

    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var segmentURL: URL?
    private var segmentStartPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var segmentStartDate = Date()
    private var recordingFlag = false
    /// The writer session begins only when the first video frame is actually
    /// accepted by the encoder. Frames arriving while the encoder spins up
    /// are held here; audio is gated to the same start time. This keeps the
    /// audio and video tracks starting at the SAME instant in every file.
    private var writerSessionStarted = false
    private var pendingVideoBuffers: [CMSampleBuffer] = []
    private var segmentLength: Double = 180
    private var writerResolution: VideoResolution = .hd
    private var audioEnabledForSession = true
    private var recordingTransform: CGAffineTransform = .identity

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session
        )
    }

    // MARK: - Session lifecycle

    /// Seconds of media time written to the current segment so far, or nil
    /// when no segment is in flight. Used to timestamp tags in the same
    /// timebase as the video file, so timeline markers stay in sync.
    func currentSegmentElapsed() -> Double? {
        segmentClock.elapsed()
    }

    func setEmergencyDetection(enabled: Bool) {
        outputQueue.async {
            self.emergencyEnabled = enabled
            if !enabled {
                DispatchQueue.main.async { self.emergencyDetection = nil }
            }
        }
    }

    func configureAndStart(resolution: VideoResolution, audioEnabled: Bool, camera: CameraSelection) {
        sessionQueue.async {
            do {
                try self.configureLocked(resolution: resolution, audioEnabled: audioEnabled, camera: camera)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.cameraAvailable = true
                    self.activeResolution = resolution
                    self.isSessionRunning = self.session.isRunning
                }
            } catch {
                DiagLog.shared.error("Capture configuration failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.cameraAvailable = false
                    self.isSessionRunning = false
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    private static func device(for camera: CameraSelection) -> AVCaptureDevice? {
        AVCaptureDevice.default(camera.deviceType, for: .video, position: camera.position)
    }

    private func configureLocked(resolution: VideoResolution, audioEnabled: Bool, camera: CameraSelection) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let cameras = CameraSelection.allCases.filter { Self.device(for: $0) != nil }
        DispatchQueue.main.async { self.availableCameras = cameras.isEmpty ? [.wide] : cameras }

        if currentCamera != camera || videoDeviceInput == nil {
            guard let device = Self.device(for: camera) ?? Self.device(for: .wide) else {
                throw CaptureError.cameraUnavailable
            }
            if let existing = videoDeviceInput {
                session.removeInput(existing)
                isoObservation?.invalidate()
                isoObservation = nil
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
            session.addInput(input)
            videoDevice = device
            videoDeviceInput = input
            currentCamera = camera
            observeISO(on: device)
            // Every camera starts at the far-range autofocus default.
            focusControlInternal = .auto
            DispatchQueue.main.async { self.focusControl = .auto }
        }

        let preset: AVCaptureSession.Preset = resolution == .uhd4k ? .hd4K3840x2160 : .hd1920x1080
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }

        if audioEnabled, audioInput == nil,
           let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        } else if !audioEnabled, let existing = audioInput {
            session.removeInput(existing)
            audioInput = nil
        }

        if !outputsAttached {
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = false
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
            session.addOutput(videoOutput)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
            outputsAttached = true
        }

        try applyAdaptiveLightingConfig()
        applyVideoStabilization()
        outputQueue.async { self.audioEnabledForSession = audioEnabled }
    }

    /// Software video stabilization on top of the always-on optical OIS.
    /// Off by default for data outputs; the phone runs on constant power, so
    /// the extra processing cost is free — and it cancels exactly the road
    /// vibration a windshield mount transmits. Cinematic preferred (stronger
    /// smoothing, modest crop), standard as fallback.
    private func applyVideoStabilization() {
        guard let device = videoDevice,
              let connection = videoOutput.connection(with: .video) else { return }
        let format = device.activeFormat
        for mode in [AVCaptureVideoStabilizationMode.cinematic, .standard]
        where format.isVideoStabilizationModeSupported(mode) {
            connection.preferredVideoStabilizationMode = mode
            DiagLog.shared.info("Video stabilization: \(mode == .cinematic ? "cinematic" : "standard") on \(currentCamera?.label ?? "camera")")
            return
        }
        DiagLog.shared.info("Video stabilization: not supported on \(currentCamera?.label ?? "camera") at current format")
    }

    /// Continuous auto exposure/white balance, HDR, low-light boost, and a
    /// locked 30 fps with exposure allowed to stretch to the full frame budget
    /// at night. Never drops below 30 fps.
    private func applyAdaptiveLightingConfig() throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        if device.activeFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = true
        }

        let frameDuration = CMTime(value: 1, timescale: 30)
        let supports30 = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }
        if supports30 {
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        }
        device.activeMaxExposureDuration = frameDuration

        // User-set brightness bias rides on top of continuous auto exposure.
        let clampedBias = min(max(exposureBiasInternal, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(clampedBias, completionHandler: nil)

        // Focus default: continuous autofocus restricted to the FAR range —
        // the road stays sharp on every camera and the lens never hunts onto
        // raindrops or the dashboard. Tap-to-focus and manual lens position
        // override until reset or camera switch.
        switch focusControlInternal {
        case .auto:
            // Meter on the center of the frame — the road ahead — and set
            // the point BEFORE the mode so the mode change adopts it.
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .far
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
        case .manual(let lensPosition):
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
            }
        case .tapped:
            break // leave the point-of-interest autofocus result untouched
        }
    }

    // MARK: - Focus & exposure control

    /// Tap-to-focus: single autofocus scan at the given device point (0-1,
    /// landscape sensor coordinates), plus exposure metering at that point.
    func focus(atDevicePoint point: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                    self.focusControlInternal = .tapped
                    DispatchQueue.main.async { self.focusControl = .tapped }
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                DiagLog.shared.error("Tap-to-focus failed: \(error.localizedDescription)")
            }
        }
    }

    /// Manual focus: lens position 0 (nearest) … 1 (infinity).
    func setLensPosition(_ position: Float) {
        sessionQueue.async {
            guard let device = self.videoDevice,
                  device.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let clamped = min(max(position, 0), 1)
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                self.focusControlInternal = .manual(clamped)
                DispatchQueue.main.async { self.focusControl = .manual(clamped) }
            } catch {
                DiagLog.shared.error("Manual focus failed: \(error.localizedDescription)")
            }
        }
    }

    /// Back to the default: far-range continuous autofocus.
    func resetFocusToAuto() {
        sessionQueue.async {
            self.focusControlInternal = .auto
            DispatchQueue.main.async { self.focusControl = .auto }
            try? self.applyAdaptiveLightingConfig()
        }
    }

    /// Exposure bias in EV; brightness control that rides on auto exposure.
    func setExposureBias(_ ev: Float) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let clamped = min(max(ev, max(-2, device.minExposureTargetBias)), min(2, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                self.exposureBiasInternal = clamped
                DispatchQueue.main.async { self.exposureBias = clamped }
            } catch {
                DiagLog.shared.error("Exposure bias failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Night detection (ISO as ambient-light proxy, with hysteresis)

    private func observeISO(on device: AVCaptureDevice) {
        isoObservation = device.observe(\.iso, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let iso = Double(device.iso)
            var newValue: Bool?
            if iso >= 600 { newValue = true }
            if iso <= 350 { newValue = false }
            guard let night = newValue else { return }
            DispatchQueue.main.async {
                if self.isNightConditions != night {
                    self.isNightConditions = night
                }
            }
        }
    }

    // MARK: - Recording control

    func startRecording(segmentLength: Double, transform: CGAffineTransform) {
        outputQueue.async {
            guard !self.recordingFlag else { return }
            self.segmentLength = max(30, segmentLength)
            self.recordingTransform = transform
            self.writerResolution = self.currentResolutionSnapshot()
            self.recordingFlag = true
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording() {
        outputQueue.async {
            guard self.recordingFlag else { return }
            self.recordingFlag = false
            self.finishCurrentSegment(isFinal: true)
            DispatchQueue.main.async { self.isRecording = false }
        }
    }

    private func currentResolutionSnapshot() -> VideoResolution {
        session.sessionPreset == .hd4K3840x2160 ? .uhd4k : .hd
    }

    // MARK: - Thermal management

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else { return }
        sessionQueue.async {
            guard self.session.sessionPreset == .hd4K3840x2160 else { return }
            // Finish the in-flight 4K segment, then drop the session to HD.
            // This safety override is the only exception to the resolution lock.
            self.outputQueue.sync {
                if self.recordingFlag {
                    self.finishCurrentSegment(isFinal: false)
                }
                self.writerResolution = .hd
            }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            self.session.commitConfiguration()
            try? self.applyAdaptiveLightingConfig()
            DiagLog.shared.info("Thermal pressure: dropped 4K to HD mid-session")
            DispatchQueue.main.async {
                self.activeResolution = .hd
                self.thermalOverrideActive = true
            }
        }
    }

    // MARK: - Interruptions

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        var reason = "The camera was interrupted."
        if let value = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let interruption = AVCaptureSession.InterruptionReason(rawValue: value) {
            switch interruption {
            case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient:
                reason = "Another app took over the camera or microphone (for example, a phone call)."
            case .videoDeviceNotAvailableInBackground:
                reason = "The app left the foreground."
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                reason = "The camera is unavailable in Split View."
            case .videoDeviceNotAvailableDueToSystemPressure:
                reason = "The camera shut down due to system pressure."
            case .sensitiveContentMitigationActivated:
                reason = "The system paused the camera for sensitive-content mitigation."
            @unknown default:
                break
            }
        }
        haltRecording(reason: .interrupted(reason))
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
            .localizedDescription ?? "A capture error occurred."
        haltRecording(reason: .error(message))
    }

    /// Finalizes the current segment cleanly and reports why recording stopped.
    private func haltRecording(reason: StopReason) {
        DiagLog.shared.error("Recording halted: \(reason)")
        outputQueue.async {
            guard self.recordingFlag else { return }
            self.recordingFlag = false
            self.finishCurrentSegment(isFinal: true)
            DispatchQueue.main.async {
                self.isRecording = false
                self.onRecordingStopped?(reason)
            }
        }
    }

    // MARK: - Segment writing (outputQueue only)

    private func beginSegment() -> Bool {
        guard let url = nextSegmentURL?(writerResolution) else { return false }

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Fragmented output: a crash or power cut loses at most ~2 s.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

            let dimensions = writerResolution.dimensions
            // H.264: the universally compatible MP4-family codec. Frame
            // reordering (B-frames) is off so decoders start instantly and
            // every frame is playable in order.
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: writerResolution.videoBitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            videoInput.transform = recordingTransform
            guard writer.canAdd(videoInput) else { return false }
            writer.add(videoInput)

            var audioWriterInput: AVAssetWriterInput?
            if audioEnabledForSession {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioWriterInput = input
                }
            }

            guard writer.startWriting() else { return false }
            // The session timeline starts later, on the first video frame
            // the encoder actually accepts — see handleVideo.

            self.writer = writer
            self.writerVideoInput = videoInput
            self.writerAudioInput = audioWriterInput
            self.segmentURL = url
            self.segmentStartPTS = nil
            self.lastVideoPTS = nil
            self.writerSessionStarted = false
            self.pendingVideoBuffers.removeAll()
            return true
        } catch {
            DiagLog.shared.error("Failed to start segment writer: \(error.localizedDescription)")
            return false
        }
    }

    private func finishCurrentSegment(isFinal: Bool) {
        guard let writer, let url = segmentURL else { return }
        let videoInput = writerVideoInput
        let audioInput = writerAudioInput
        let startedAt = segmentStartDate
        let startPTS = segmentStartPTS
        let endPTS = lastVideoPTS
        let resolution = writerResolution
        let sessionStarted = writerSessionStarted

        self.writer = nil
        self.writerVideoInput = nil
        self.writerAudioInput = nil
        self.segmentURL = nil
        self.segmentStartPTS = nil
        self.writerSessionStarted = false
        self.pendingVideoBuffers.removeAll()
        self.segmentClock.clear()

        // No frame ever made it into this file: discard it quietly instead
        // of finalizing an empty movie.
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting {
            if writer.status == .failed {
                DiagLog.shared.error(
                    "Segment \(url.lastPathComponent) failed to finalize: \(writer.error?.localizedDescription ?? "unknown")"
                )
            }
            var duration = 0.0
            if let startPTS, let endPTS {
                duration = max(0, CMTimeGetSeconds(CMTimeSubtract(endPTS, startPTS)))
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let result = SegmentResult(
                url: url,
                fileName: url.lastPathComponent,
                startedAt: startedAt,
                duration: duration,
                resolution: resolution,
                fileSize: size,
                isFinal: isFinal
            )
            DispatchQueue.main.async { self.onSegmentFinished?(result) }
        }
    }

    private func stopBecauseStorageIsFull() {
        DiagLog.shared.error("Recording stopped: storage budget exhausted even with LOOP empty")
        recordingFlag = false
        finishCurrentSegment(isFinal: true)
        DispatchQueue.main.async {
            self.isRecording = false
            self.onRecordingStopped?(.storageFull)
        }
    }
}

/// Thread-safe media-time clock for the in-flight segment: written on the
/// capture output queue, read from the main actor when a tag is placed.
private final class SegmentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startPTS: CMTime?
    private var lastPTS: CMTime?

    func reset(start: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        startPTS = start
        lastPTS = start
    }

    func update(_ pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        lastPTS = pts
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        startPTS = nil
        lastPTS = nil
    }

    func elapsed() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let startPTS, let lastPTS else { return nil }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(lastPTS, startPTS)))
    }
}

// MARK: - Sample buffer delegates

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            analyzeForEmergencyLights(sampleBuffer, pts: pts)
            guard recordingFlag else { return }
            handleVideo(sampleBuffer, pts: pts)
        } else if output === audioOutput {
            // Audio only joins once the video session has started, so both
            // tracks begin at the same instant in the file.
            guard recordingFlag,
                  writerSessionStarted,
                  let input = writerAudioInput,
                  input.isReadyForMoreMediaData,
                  let start = segmentStartPTS,
                  CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
            input.append(sampleBuffer)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        if writer == nil {
            guard beginSegment() else {
                stopBecauseStorageIsFull()
                return
            }
        }

        // Rotate at the segment boundary; the triggering frame is buffered
        // into the next writer below, so no frame is lost at the seam.
        if writerSessionStarted,
           let start = segmentStartPTS,
           CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= segmentLength {
            finishCurrentSegment(isFinal: false)
            guard beginSegment() else {
                stopBecauseStorageIsFull()
                return
            }
        }

        guard let writer, let videoInput = writerVideoInput else { return }

        if !writerSessionStarted {
            // Hold frames until the encoder accepts input, then start the
            // session exactly at the first frame that goes into the file.
            pendingVideoBuffers.append(sampleBuffer)
            if pendingVideoBuffers.count > 12 {
                pendingVideoBuffers.removeFirst()
            }
            guard videoInput.isReadyForMoreMediaData,
                  let first = pendingVideoBuffers.first else { return }

            let startPTS = CMSampleBufferGetPresentationTimeStamp(first)
            writer.startSession(atSourceTime: startPTS)
            writerSessionStarted = true
            segmentStartPTS = startPTS
            segmentClock.reset(start: startPTS)
            let bufferedSpan = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, startPTS)))
            segmentStartDate = Date().addingTimeInterval(-bufferedSpan)

            for buffered in pendingVideoBuffers {
                guard videoInput.isReadyForMoreMediaData else { break }
                videoInput.append(buffered)
                let bufferedPTS = CMSampleBufferGetPresentationTimeStamp(buffered)
                lastVideoPTS = bufferedPTS
                segmentClock.update(bufferedPTS)
            }
            pendingVideoBuffers.removeAll()

            if let fileName = segmentURL?.lastPathComponent {
                let startedAt = segmentStartDate
                DispatchQueue.main.async { self.onSegmentStarted?(fileName, startedAt) }
            }
            return
        }

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
            lastVideoPTS = pts
            segmentClock.update(pts)
        }
    }

    /// Samples every 4th frame (~7.5 fps) on a low-priority queue so rapid
    /// strobes register; frames are skipped rather than queued if analysis
    /// is still running.
    private func analyzeForEmergencyLights(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        frameCounter += 1

        // Road-scene taps run on their own cadences and drop frames when busy.
        if frameCounter % 2 == 0, let lampSink = roadLampSink,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lampSink(pixelBuffer, CMTimeGetSeconds(pts))
        }
        if frameCounter % 6 == 0, let sink = roadFrameSink,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            sink(pixelBuffer, CMTimeGetSeconds(pts))
        }

        guard emergencyEnabled,
              frameCounter % 4 == 0,
              !analyzerBusy,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        analyzerBusy = true
        let time = CMTimeGetSeconds(pts)
        let exclusions = emergencyExclusionProvider?() ?? []
        analyzerQueue.async {
            defer { self.outputQueue.async { self.analyzerBusy = false } }
            guard let stats = EmergencyFrameAnalyzer.scan(pixelBuffer, at: time, excluding: exclusions) else { return }
            let result = self.emergencyDetector.process(stats)
            DispatchQueue.main.async {
                if let box = result.activeBox {
                    self.emergencyDetection = EmergencyDetection(box: box, time: time)
                } else if self.emergencyDetection != nil {
                    self.emergencyDetection = nil
                }
                if result.shouldTag {
                    DiagLog.shared.info("Emergency lights detected — auto-tagging")
                    self.onEmergencyLights?()
                }
            }
        }
    }
}
