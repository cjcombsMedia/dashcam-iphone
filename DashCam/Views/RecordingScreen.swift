import SwiftUI

/// Main screen: full camera preview with telemetry overlay and controls, or
/// the dimmed HUD after the inactivity timeout. The pulsing red indicator is
/// visible in both modes.
struct RecordingScreen: View {
    @EnvironmentObject private var vm: RecordingViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offload: OffloadService
    @EnvironmentObject private var roadScene: RoadScene
    @EnvironmentObject private var roadMemory: RoadMemory

    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorID = 0
    @State private var showManualPanel = false
    /// The remembered sign a long press asked to remove.
    @State private var forgetCandidate: RoadFeatureType?
    @State private var forgetResult: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch vm.screenMode {
            case .full:
                fullPreview
            case .hud:
                HUDView(
                    location: vm.location,
                    unit: settings.speedUnit,
                    night: vm.isNight,
                    fallbackHeading: vm.motionHeading,
                    showRecording: vm.capture.isRecording,
                    tagAction: { vm.tag(source: .manual) }
                )
            }

            if vm.capture.isRecording, vm.screenMode == .full {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        PulsingRecordIndicator(night: vm.isNight)
                            .padding(20)
                    }
                }
            }

            if vm.tagFlash {
                TagFlashOverlay()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.screenMode)
        .animation(.easeInOut(duration: 0.2), value: vm.tagFlash)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { vm.noteInteraction() }
        )
        .statusBarHidden()
        .fullScreenCover(isPresented: $vm.showStartupModal) {
            StartupAcknowledgmentView { vm.acknowledgeStartup() }
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $vm.showLibrary) {
            LibraryView()
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView()
        }
        .alert("Recording stopped — storage full", isPresented: $vm.storageFullAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("There is no room for new footage even with the loop folder empty. Export or delete Saved clips, or free up space on this iPhone.")
        }
        .alert(
            "Recording interrupted",
            isPresented: Binding(
                get: { vm.interruptionMessage != nil },
                set: { if !$0 { vm.interruptionMessage = nil } }
            )
        ) {
            Button("Resume recording") { vm.resumeAfterInterruption() }
            Button("Not now", role: .cancel) { vm.interruptionMessage = nil }
        } message: {
            Text(vm.interruptionMessage ?? "")
        }
        .alert(
            "Road memory",
            isPresented: Binding(
                get: { offload.importMessage != nil },
                set: { if !$0 { offload.importMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(offload.importMessage ?? "")
        }
        .alert("Allow location all the time", isPresented: $vm.showLocationSettingsAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Set Location to “Always” in Settings so the GPS fix stays locked for the whole drive.")
        }
        .onChange(of: settings.resolution) { vm.resolutionChanged() }
        .onChange(of: settings.audioEnabled) { vm.audioSettingChanged() }
        .onChange(of: settings.camera) { vm.cameraChanged() }
        .onChange(of: settings.emergencyLightDetection) {
            vm.capture.setEmergencyDetection(enabled: settings.emergencyLightDetection)
        }
        .onChange(of: settings.roadDetection) {
            roadScene.analyzer?.isEnabled = settings.roadDetection
        }
        .onChange(of: vm.showLibrary) {
            vm.libraryVisibilityChanged(isOpen: vm.showLibrary)
        }
        .onChange(of: vm.showSettings) {
            vm.sheetVisibilityChanged(isOpen: vm.showSettings)
        }
        .confirmationDialog(
            forgetCandidate.map { "Remove \($0.label) from memory?" } ?? "",
            isPresented: Binding(
                get: { forgetCandidate != nil },
                set: { if !$0 { forgetCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let type = forgetCandidate { forget(type) }
                forgetCandidate = nil
            }
            Button("Keep", role: .cancel) { forgetCandidate = nil }
        } message: {
            Text("This sign won't show here again, the camera won't relearn it, and the removal is sent to DashCam Studio so your Mac stops exporting it.")
        }
        .alert(
            "Road memory",
            isPresented: Binding(
                get: { forgetResult != nil },
                set: { if !$0 { forgetResult = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(forgetResult ?? "")
        }
        .task {
            vm.bootstrap()
            offload.applyConnectionSetting()
            // Pick up any transfers interrupted by a crash or force-quit.
            await offload.resumeIfNeeded()
        }
    }

    // MARK: - Full preview

    private var fullPreview: some View {
        ZStack {
            if vm.capture.cameraAvailable {
                CameraPreviewView(session: vm.capture.session) { devicePoint, layerPoint in
                    vm.capture.focus(atDevicePoint: devicePoint)
                    focusIndicatorPoint = layerPoint
                    focusIndicatorID += 1
                    let id = focusIndicatorID
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if focusIndicatorID == id {
                            focusIndicatorPoint = nil
                        }
                    }
                }
                .ignoresSafeArea()
                if let point = focusIndicatorPoint {
                    FocusSquare()
                        .position(point)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                if let detection = vm.capture.emergencyDetection {
                    EmergencyBoxOverlay(
                        detection: detection,
                        videoDimensions: vm.capture.activeResolution.dimensions
                    )
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash.fill")
                        .font(.largeTitle)
                    Text("Camera unavailable")
                        .font(.headline)
                    Text("Connect a real device — the Simulator has no camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }

            VStack(spacing: 0) {
                topBar
                if roadScene.fireStationUntil != nil, let label = roadScene.fireStationLabel {
                    FireStationBanner(label: label)
                        .padding(.top, 6)
                }
                if vm.lowLoopCapacity || offloadBannerText != nil || roadScene.cityUntil != nil
                    || vm.telemetryWarning != nil {
                    VStack(spacing: 6) {
                        // A drive that isn't saving its overlays is worthless
                        // as evidence — say so now, not on review day.
                        if let warning = vm.telemetryWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.bold())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.yellow, in: Capsule())
                        }
                        if roadScene.cityUntil != nil, let city = roadScene.cityName {
                            Label("Welcome to \(city)", systemImage: "signpost.right.fill")
                                .font(.footnote.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(red: 0, green: 0.45, blue: 0.23).opacity(0.9), in: Capsule())
                        }
                        if vm.lowLoopCapacity { StorageWarningBanner() }
                        if let text = offloadBannerText {
                            Label(text, systemImage: "externaldrive.badge.wifi")
                                .font(.footnote.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.blue.opacity(0.8), in: Capsule())
                        }
                    }
                    .padding(.top, 6)
                }
                // Detected road signs & signal mocks (signal is speed-gated).
                HStack {
                    RoadSignsOverlay(
                        scene: roadScene,
                        showSignal: vm.signalGateOpen,
                        onForget: { type in forgetCandidate = type },
                        vehicleHeightInches: settings.vehicleHeightInches > 0
                            ? settings.vehicleHeightInches : nil
                    )
                    Spacer()
                }
                .padding(.top, 8)
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Humans detected mid-frame (crosswalks).
            if !roadScene.pedestrianBoxes.isEmpty {
                PedestrianBoxesOverlay(
                    boxes: roadScene.pedestrianBoxes,
                    videoDimensions: vm.capture.activeResolution.dimensions
                )
            }

            // Cyclist warning arrow at the side it was detected on.
            if let cyclist = roadScene.cyclist {
                CyclistWarningView(direction: cyclist.direction)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: cyclist.direction == .right ? .trailing : .leading
                    )
                    .padding(.horizontal, 70)
            }

            VStack {
                Spacer()
                HStack {
                    TelemetryOverlay(
                        location: vm.location,
                        unit: settings.speedUnit,
                        night: vm.isNight,
                        fallbackHeading: vm.motionHeading,
                        vibrationG: vm.vibrationG,
                        thermalRaw: vm.thermalRaw
                    )
                    .padding(.leading, 110)
                    .padding(.bottom, 14)
                    Spacer()
                }
            }

            // Quick screen controls: day/night mode and on-demand dim.
            VStack(spacing: 12) {
                if vm.capture.thermalOverrideActive {
                    // Compact heat caution: 4K was dropped to HD mid-session.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                        .accessibilityLabel("iPhone is hot — recording dropped to HD")
                }
                Button {
                    vm.toggleDayNight()
                } label: {
                    Image(systemName: settings.nightScreenMode ? "moon.stars.fill" : "sun.max.fill")
                        .font(.title3)
                        .foregroundStyle(settings.nightScreenMode ? .orange : .yellow)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityIdentifier("dayNightButton")
                .accessibilityLabel(settings.nightScreenMode ? "Switch to day mode" : "Switch to night mode")

                Button {
                    vm.dimNow()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.title3)
                        Text("DIM")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityIdentifier("dimButton")
                .accessibilityLabel("Dim screen now")

                Button {
                    showManualPanel.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(showManualPanel ? .yellow : .white)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityIdentifier("manualPanelButton")
                .accessibilityLabel("Manual focus and brightness")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 16)

            if showManualPanel {
                ManualCameraPanel(capture: vm.capture) {
                    showManualPanel = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 70)
                .padding(.bottom, 90)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showManualPanel)
    }

    /// Removes the remembered sign and pushes the removal to the Mac, so it
    /// can't come back on the next import.
    private func forget(_ type: RoadFeatureType) {
        guard let removed = roadMemory.forgetActive(type: type) else {
            forgetResult = "That sign was already gone."
            return
        }
        Haptics.tagConfirmed()
        let place = String(format: "%.5f, %.5f", removed.latitude, removed.longitude)
        Task {
            let synced = await offload.syncForgottenFeatures()
            forgetResult = synced > 0
                ? "\(type.label) removed at \(place), and DashCam Studio was told to stop exporting it."
                : "\(type.label) removed at \(place). Studio isn't reachable — the removal will be sent the next time you connect."
        }
    }

    private var offloadBannerText: String? {
        switch offload.status {
        case .offloading(let done, let total):
            if let current = offload.activeUploads.first {
                return "Offloading \(done)/\(total) — \(current.fileName) \(Int(current.fraction * 100))%"
            }
            return "Offloading to Mac — \(done)/\(total) files"
        case .finished(let clips, let bytes) where clips > 0:
            return offload.lastRunWasCopy
                ? "Sent \(clips) clip\(clips == 1 ? "" : "s") to Studio (\(Format.fileSize(bytes))) — kept on phone"
                : "Offloaded \(clips) clips (\(Format.fileSize(bytes))) — phone cleared"
        default:
            return nil
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                vm.showLibrary = true
            } label: {
                Image(systemName: "photo.stack")
                    .font(.title3)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityIdentifier("libraryButton")
            Button {
                vm.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityIdentifier("settingsButton")
            .disabled(vm.capture.isRecording)
            .opacity(vm.capture.isRecording ? 0.4 : 1)
            if vm.locationNotAlways {
                Button {
                    vm.requestAlwaysLocation()
                } label: {
                    Image(systemName: "location.slash.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityIdentifier("locationAlwaysChip")
                .accessibilityLabel("Location access is not set to Always — tap to fix")
            }
            Spacer(minLength: 4)
            Menu {
                Picker("Camera", selection: $settings.camera) {
                    ForEach(vm.capture.availableCameras) { camera in
                        Label(camera.label, systemImage: camera.systemImage).tag(camera)
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title3)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityIdentifier("cameraMenu")
            .disabled(vm.capture.isRecording)
            .opacity(vm.capture.isRecording ? 0.45 : 1)
            Button {
                settings.audioEnabled.toggle()
            } label: {
                Image(systemName: settings.audioEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.title2)
                    .foregroundStyle(settings.audioEnabled ? .white : .red)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .disabled(vm.capture.isRecording)
            .opacity(vm.capture.isRecording ? 0.45 : 1)
            ResolutionSelector(
                resolution: $settings.resolution,
                locked: vm.capture.isRecording
            )
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        ZStack {
            HStack {
                RecordButton(
                    isRecording: vm.capture.isRecording,
                    enabled: vm.acknowledged && vm.capture.cameraAvailable
                ) {
                    vm.toggleRecording()
                }
                Spacer()
            }
            if vm.capture.isRecording {
                TagButton(night: vm.isNight) {
                    vm.tag(source: .manual)
                }
            }
        }
        .padding(.bottom, 6)
    }
}
