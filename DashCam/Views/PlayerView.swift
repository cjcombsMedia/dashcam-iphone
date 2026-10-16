import AVFoundation
import SwiftUI

/// Clip replay that looks exactly like the live recording screen: fullscreen
/// video with the gray telemetry box (speed, heading, GPS, time) and the
/// green emergency box replay. All controls are hidden by default — tap
/// anywhere to reveal back / export / scrubber / tags, tap again to hide.
struct PlayerView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offload: OffloadService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let clip: ClipSegment

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var isReadyToPlay = false
    @State private var loadFailed = false
    @State private var statusObservation: NSKeyValueObservation?
    @State private var readinessTimeoutTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var showExportOptions = false
    @State private var showControls = false
    @State private var telemetryTimeline: [(offset: Double, sample: TelemetrySample)] = []
    @State private var currentSample: TelemetrySample?
    @State private var emergencyEvents: [EmergencyEvent] = []
    @State private var currentEmergencyBox: CGRect?
    @State private var overlaySnapshots: [OverlaySnapshot] = []
    @State private var currentOverlay: OverlaySnapshot?
    @State private var sentToStudio = false

    private var sortedTags: [TagMark] {
        clip.tags.sorted { $0.offsetInClip < $1.offsetInClip }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: player)
                .ignoresSafeArea()

            if let box = currentEmergencyBox {
                PlaybackEmergencyBox(box: box, videoDimensions: clip.resolution.dimensions)
                    .ignoresSafeArea()
            }

            // Everything the live screen showed, reconstructed from the
            // recorded overlay snapshots.
            if let overlay = currentOverlay {
                ReplayOverlayView(snapshot: overlay, videoDimensions: clip.resolution.dimensions)
            }

            // The same gray box as the live screen, driven by the sidecar.
            if let sample = currentSample {
                VStack {
                    Spacer()
                    HStack {
                        TelemetryBox(
                            speedMPS: sample.speedMPS ?? -1,
                            headingDegrees: sample.headingDegrees ?? -1,
                            latitude: sample.latitude,
                            longitude: sample.longitude,
                            fix: sample.latitude != nil ? .good : .none,
                            unit: settings.speedUnit,
                            night: false,
                            timestamp: sample.timestamp,
                            vibrationG: sample.vibrationG,
                            thermalRaw: sample.thermal
                        )
                        .padding(.leading, 24)
                        .padding(.bottom, 20)
                        Spacer()
                    }
                }
            }

            // Transfer progress lives here too — the recording screen's
            // offload banner isn't visible while a clip is open.
            if sentToStudio {
                VStack {
                    studioTransferChip
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.opacity)
            }

            // A clip with no recorded telemetry replays as bare video. Say so
            // rather than leaving a blank screen that looks like broken replay.
            if isReadyToPlay, telemetryTimeline.isEmpty, overlaySnapshots.isEmpty {
                VStack {
                    HStack {
                        Spacer()
                        Label("No telemetry recorded for this clip", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.trailing, 20)
                            .padding(.top, 14)
                    }
                    Spacer()
                }
            }

            if !isReadyToPlay && !loadFailed {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading clip…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            if loadFailed {
                Label("This clip couldn't be loaded", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.yellow)
            }
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Exporting with telemetry overlay…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(18)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }

            if showControls {
                controlsOverlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { showControls.toggle() }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )
        ) {
            if let shareURL {
                ActivityShareSheet(items: [shareURL])
            }
        }
        .alert("Export this clip", isPresented: $showExportOptions) {
            ForEach(ExportMode.allCases) { mode in
                Button(mode.label) {
                    Task { await runExport(mode: mode) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Video only — clean footage, fastest.\nBasic overlay — telemetry text along the bottom.\nFull graphical — everything the live screen showed.")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        // Keyed by clip: SwiftUI reuses this view when you open a second
        // clip, so without an id the reload never re-fires and the previous
        // clip's overlay state lingers (or vanishes).
        .task(id: clip.id) { await preparePlayer() }
        .onDisappear {
            statusObservation?.invalidate()
            statusObservation = nil
            readinessTimeoutTask?.cancel()
            readinessTimeoutTask = nil
            player.pause()
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
        }
    }

    // MARK: - Controls (hidden until tapped)

    // MARK: - Send to Studio

    @ViewBuilder
    private var studioTransferChip: some View {
        if let upload = offload.activeUploads.first {
            VStack(spacing: 4) {
                Label(
                    "Sending to Studio — \(Int(upload.fraction * 100))%",
                    systemImage: "laptopcomputer.and.arrow.down"
                )
                .font(.caption.bold())
                ProgressView(value: upload.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 190)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        } else if !offload.isBusy {
            Label("Sent to DashCam Studio — copy kept on phone", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }

    private var studioButtonTitle: String {
        if sentToStudio { return "Sent" }
        if offload.isBusy { return "Sending…" }
        return offload.helperFound ? "Send to Studio" : "Studio offline"
    }

    private var studioButtonIcon: String {
        if sentToStudio { return "checkmark.circle.fill" }
        if offload.isBusy { return "arrow.triangle.2.circlepath" }
        return offload.helperFound ? "laptopcomputer.and.arrow.down" : "laptopcomputer.slash"
    }

    /// Uploads this clip and its telemetry to the Mac. Deliberately a copy —
    /// the clip you're watching stays on the phone. Bulk offload from the
    /// Library is still the move-and-reclaim path.
    private func sendToStudio() {
        guard offload.helperFound, !offload.isBusy else { return }
        offload.startOffload(clips: [clip], removeFromPhone: false)
        sentToStudio = true
        Haptics.tagConfirmed()
        DiagLog.shared.info("Player: sent \(clip.fileName) to DashCam Studio (copy)")
    }

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                Button {
                    sendToStudio()
                } label: {
                    Label(studioButtonTitle, systemImage: studioButtonIcon)
                        .font(.headline)
                        .foregroundStyle(sentToStudio ? .green : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .disabled(!offload.helperFound || offload.isBusy || sentToStudio)
                .help(offload.helperFound
                      ? "Send this clip to DashCam Studio on your Mac"
                      : "DashCam Studio isn't on this network")
                .accessibilityIdentifier("playerSendToStudioButton")

                Button {
                    showExportOptions = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .disabled(isExporting)
                .accessibilityIdentifier("playerExportButton")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                scrubber
                HStack {
                    Text(Format.duration(currentTime))
                        .font(.caption.monospaced())
                    Spacer()
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isReadyToPlay)
                    Spacer()
                    Text(Format.duration(duration))
                        .font(.caption.monospaced())
                }
                if !sortedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sortedTags) { tag in
                                Button {
                                    seek(to: tag.offsetInClip)
                                } label: {
                                    Label(
                                        "\(tag.source.label) @ \(Format.duration(tag.offsetInClip))",
                                        systemImage: tag.source.systemImage
                                    )
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.yellow.opacity(0.25), in: Capsule())
                                    .foregroundStyle(.yellow)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.gray.opacity(0.45))
                    .frame(height: 6)
                Capsule()
                    .fill(.red)
                    .frame(width: max(0, progress * width), height: 6)

                ForEach(sortedTags) { tag in
                    let fraction = duration > 0 ? min(1, max(0, tag.offsetInClip / duration)) : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.yellow)
                        .frame(width: 3, height: 18)
                        .position(x: fraction * width, y: 14)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .position(x: progress * width, y: 14)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        seek(to: fraction * duration)
                    }
            )
        }
        .frame(height: 28)
    }

    // MARK: - Export / share

    private func runExport(mode: ExportMode) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        player.pause()
        isPlaying = false

        do {
            shareURL = try await library.burnedExportURL(for: clip, mode: mode)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Player plumbing

    private func preparePlayer() async {
        // Full reset — this view is reused across clips.
        statusObservation?.invalidate()
        statusObservation = nil
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        if let existing = timeObserver {
            player.removeTimeObserver(existing)
            timeObserver = nil
        }
        player.pause()
        isPlaying = false
        isReadyToPlay = false
        loadFailed = false
        currentTime = 0
        telemetryTimeline = []
        currentSample = nil
        emergencyEvents = []
        currentEmergencyBox = nil
        overlaySnapshots = []
        currentOverlay = nil
        sentToStudio = false

        duration = clip.duration

        // The capture session leaves the audio session in record mode, and
        // AVPlayer holds VIDEO until audio is renegotiated. Claim a playback
        // session up front so both tracks start immediately.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)

        // Telemetry overlay + emergency box replay data.
        if let sidecar = library.sidecar(for: clip) {
            telemetryTimeline = sidecar.samples
                .map { ($0.timestamp.timeIntervalSince(sidecar.startedAt), $0) }
                .sorted { $0.0 < $1.0 }
            currentSample = telemetryTimeline.first?.sample
            emergencyEvents = (sidecar.emergencyEvents ?? []).sorted { $0.offset < $1.offset }
            overlaySnapshots = (sidecar.overlaySnapshots ?? []).sorted { $0.offset < $1.offset }
            currentOverlay = overlaySnapshots.first
        }

        // Never hand the player a fragmented file. Express-lane remux to
        // flat .mp4 behind the loading spinner; only success is recorded.
        if !clip.isOptimized {
            let url = library.videoURL(for: clip)
            if let result = await SegmentOptimizer.shared.optimizeNow(fileURL: url), result.bytes > 0 {
                clip.fileName = result.fileName
                clip.fileSize = result.bytes
                clip.isOptimized = true
                try? modelContext.save()
            }
        }

        let asset = AVURLAsset(url: library.videoURL(for: clip))
        let item = AVPlayerItem(asset: asset)
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)

        let openedAt = Date()
        let fileName = clip.fileName
        statusObservation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            let status = observedItem.status
            let errorText = observedItem.error?.localizedDescription
            DispatchQueue.main.async {
                switch status {
                case .readyToPlay:
                    guard !isReadyToPlay else { return }
                    DiagLog.shared.info(
                        String(format: "Player ready in %.2fs for %@", Date().timeIntervalSince(openedAt), fileName)
                    )
                    isReadyToPlay = true
                    // Replay looks live: start playing immediately.
                    player.playImmediately(atRate: 1.0)
                    isPlaying = true
                case .failed:
                    loadFailed = true
                    DiagLog.shared.error("Player failed to load \(fileName): \(errorText ?? "unknown")")
                default:
                    break
                }
            }
        }

        readinessTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, !isReadyToPlay, !loadFailed else { return }
            DiagLog.shared.error(
                "Player readiness timed out after 10s for \(fileName) (status \(item.status.rawValue)); enabling playback anyway"
            )
            isReadyToPlay = true
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = CMTimeGetSeconds(time)
            if duration > 0, currentTime >= duration - 0.05 {
                isPlaying = false
            }
            if !telemetryTimeline.isEmpty {
                currentSample = telemetryTimeline.last(where: { $0.offset <= currentTime })?.sample
                    ?? telemetryTimeline.first?.sample
            }
            if !emergencyEvents.isEmpty {
                currentEmergencyBox = emergencyEvents
                    .first(where: { abs($0.offset - currentTime) < 0.6 })?
                    .box
            }
            if !overlaySnapshots.isEmpty {
                currentOverlay = overlaySnapshots.last(where: { $0.offset <= currentTime })
                    ?? overlaySnapshots.first
            }
        }

        if let loaded = try? await asset.load(.duration),
           loaded.isNumeric, CMTimeGetSeconds(loaded) > 0 {
            duration = CMTimeGetSeconds(loaded)
        }
    }

    private func togglePlayback() {
        guard isReadyToPlay else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.playImmediately(atRate: 1.0)
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

/// Reconstructs the live overlay (signs, signal, cyclist, pedestrian boxes)
/// from a recorded snapshot, so replay matches what the drive looked like.
private struct ReplayOverlayView: View {
    let snapshot: OverlaySnapshot
    let videoDimensions: CGSize

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top, spacing: 10) {
                    if let limit = snapshot.speedLimit {
                        SpeedLimitSignView(limit: limit)
                    }
                    if snapshot.humpShowing {
                        SpeedHumpSignView(speed: snapshot.humpSpeed)
                    }
                    if snapshot.schoolShowing {
                        SchoolCrossingSignView(speed: snapshot.schoolSpeed)
                    }
                    if snapshot.hospitalShowing {
                        HospitalSignView()
                    }
                    if snapshot.bikeShowing {
                        BikeLaneSignView()
                    }
                    if let signal = snapshot.signal, let kind = Self.signalKind(signal) {
                        TrafficSignalMockView(kind: kind)
                    }
                    Spacer()
                }
                if let fireStation = snapshot.fireStation {
                    FireStationBanner(label: fireStation)
                        .padding(.top, 6)
                }
                if let city = snapshot.cityName {
                    HStack {
                        Label("Welcome to \(city)", systemImage: "signpost.right.fill")
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(red: 0, green: 0.45, blue: 0.23).opacity(0.9), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if let boxes = snapshot.pedestrians {
                PedestrianBoxesOverlay(
                    boxes: boxes.compactMap { values in
                        values.count == 4
                            ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                            : nil
                    },
                    videoDimensions: videoDimensions
                )
            }

            if let side = snapshot.cyclist {
                CyclistWarningView(direction: side == "right" ? .right : .left)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: side == "right" ? .trailing : .leading
                    )
                    .padding(.horizontal, 70)
            }
        }
        .allowsHitTesting(false)
    }

    private static func signalKind(_ raw: String) -> SignalDisplayKind? {
        switch raw {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "flashingYellow": return .flashingYellow
        default: return nil
        }
    }
}

/// Green detection box replayed over playback, mapped through the player's
/// aspect-FILL crop (matching the live preview's framing).
private struct PlaybackEmergencyBox: View {
    let box: CGRect
    let videoDimensions: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = mappedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Text("EMERGENCY LIGHTS")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
                    .offset(x: rect.minX, y: max(0, rect.minY - 18))
            }
            .animation(.easeInOut(duration: 0.15), value: box)
        }
        .allowsHitTesting(false)
    }

    private func mappedRect(in viewSize: CGSize) -> CGRect {
        guard videoDimensions.width > 0, videoDimensions.height > 0 else { return .zero }
        let scale = max(viewSize.width / videoDimensions.width, viewSize.height / videoDimensions.height)
        let drawnWidth = videoDimensions.width * scale
        let drawnHeight = videoDimensions.height * scale
        let offsetX = (viewSize.width - drawnWidth) / 2
        let offsetY = (viewSize.height - drawnHeight) / 2
        return CGRect(
            x: offsetX + box.minX * drawnWidth,
            y: offsetY + box.minY * drawnHeight,
            width: box.width * drawnWidth,
            height: box.height * drawnHeight
        )
    }
}

/// UIActivityViewController wrapper for AirDrop / Mail / Files sharing.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Minimal AVPlayerLayer host; fills the screen like the live preview.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
