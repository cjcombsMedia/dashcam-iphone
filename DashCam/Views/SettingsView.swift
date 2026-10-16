import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vm: RecordingViewModel
    @EnvironmentObject private var offload: OffloadService
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var simulateFullDisk = false
    @State private var showTrainingMode = false
    @State private var showRoadMemory = false
    @State private var showFieldTag = false
    @State private var loopBytes: Int64 = 0
    @State private var savedBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0
    @State private var generatingSample = false
    @State private var confirmOffloadEverything = false
    @State private var cacheMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Camera", selection: $settings.camera) {
                        ForEach(vm.capture.availableCameras) { camera in
                            Text(camera.label).tag(camera)
                        }
                    }
                    .disabled(vm.capture.isRecording)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("The main screen previews exactly what the selected camera will record. Locked while recording.")
                }

                Section {
                    Toggle("Use location all the time", isOn: $settings.alwaysLocation)
                        .onChange(of: settings.alwaysLocation) {
                            if settings.alwaysLocation { vm.requestAlwaysLocation() }
                        }
                    LabeledContent("Current access", value: locationStatusText)
                    if vm.locationNotAlways {
                        Button("Enable Always access") {
                            vm.requestAlwaysLocation()
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Always access keeps the GPS fix locked for speed and route logging on a dash-mounted phone. GPS works fully offline — no network needed.")
                }

                Section("Recording") {
                    Picker("Segment length", selection: $settings.segmentLength) {
                        Text("1 min").tag(60.0)
                        Text("2 min").tag(120.0)
                        Text("3 min").tag(180.0)
                        Text("5 min").tag(300.0)
                    }
                    Toggle("Record audio", isOn: $settings.audioEnabled)
                        .disabled(vm.capture.isRecording)
                }

                Section("Display") {
                    Picker("Dim to HUD after", selection: $settings.hudDimDelay) {
                        Text("1 min").tag(60.0)
                        Text("2 min").tag(120.0)
                        Text("3 min").tag(180.0)
                        Text("5 min").tag(300.0)
                        Text("10 min").tag(600.0)
                    }
                }

                Section {
                    Picker("Sensitivity", selection: $settings.sensitivity) {
                        ForEach(AutoTagSensitivity.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.sensitivity) {
                        vm.motion.updateSensitivity(settings.sensitivity)
                    }
                    Toggle("Detect emergency lights", isOn: $settings.emergencyLightDetection)
                } header: {
                    Text("Auto-tag")
                } footer: {
                    Text("Impacts and hard braking automatically tag the current segment and move it to Saved. Emergency-light detection watches for flashing red/blue strobes fully on-device (offline), draws a green box around them, and auto-tags.")
                }

                Section {
                    Toggle("Road signs & signals", isOn: $settings.roadDetection)
                    Picker("Vehicle height", selection: $settings.vehicleHeightInches) {
                        Text("Not set").tag(0)
                        ForEach([72, 78, 84, 90, 96, 102, 108, 114, 120, 126, 132, 138, 144, 150, 156, 162], id: \.self) { inches in
                            Text("\(inches / 12)' \(inches % 12)\"").tag(inches)
                        }
                    }
                    Button {
                        showFieldTag = true
                    } label: {
                        Label("Tag a sign here", systemImage: "mappin.and.ellipse")
                    }
                    Button {
                        showRoadMemory = true
                    } label: {
                        Label("Road memory", systemImage: "map")
                    }
                    Button {
                        showTrainingMode = true
                    } label: {
                        Label("Detection test / training", systemImage: "photo.badge.checkmark")
                    }
                } header: {
                    Text("Road Detection")
                } footer: {
                    Text("Reads speed limit, stop, yield, do-not-enter, railroad, pedestrian-crossing, speed hump, hospital, bike-route, school, city and fire-station signs, traffic signal colors, cyclists, and pedestrians — fully on-device. Confirmed signs are remembered by location and direction, so familiar roads show them even when the camera can't read the sign (marked with an M).\n\nTag a sign here pins a sign by standing next to it, which is far more precise than reading it at speed from the car.\n\nSet your vehicle height and a posted bridge clearance at or below it turns red instead of green.")
                }

                Section("Startup") {
                    Toggle("Show startup reminder", isOn: $settings.showStartupReminder)
                }

                Section {
                    LabeledContent(
                        "Loop capacity at \(settings.resolution.label)",
                        value: capacityText(for: settings.resolution)
                    )
                    LabeledContent(
                        "Loop capacity at \(otherResolution.label)",
                        value: capacityText(for: otherResolution)
                    )
                    LabeledContent("Loop folder", value: Format.fileSize(loopBytes))
                    LabeledContent("Saved folder", value: Format.fileSize(savedBytes))
                    LabeledContent("Free space", value: Format.fileSize(freeBytes))
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Footage is capped at 75% of available space. Oldest loop clips are overwritten first; Saved clips are never auto-deleted.")
                }

                Section {
                    // The only switch here. It controls the link, never a
                    // transfer — nothing uploads unless you press a button.
                    Toggle("Connect to DashCam Studio", isOn: Binding(
                        get: { settings.studioConnectionEnabled },
                        set: { enabled in
                            settings.studioConnectionEnabled = enabled
                            offload.applyConnectionSetting()
                        }
                    ))
                    LabeledContent("Status", value: offloadStatusText)
                    ForEach(offload.activeUploads) { upload in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(upload.fileName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: upload.fraction)
                            Text("\(Format.fileSize(upload.bytesSent)) of \(Format.fileSize(upload.totalBytes)) · \(Int(upload.fraction * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                    if let summary = offload.lastRunSummary {
                        LabeledContent("Last run", value: summary)
                    }
                    Button("Offload all videos") {
                        confirmOffloadEverything = true
                    }
                    .disabled(!offload.helperFound || offload.isBusy || vm.capture.isRecording)

                    Button("Import road memory from Mac") {
                        Task { await offload.importRoadMemory() }
                    }
                    .disabled(!offload.helperFound || offload.isBusy)

                    Button("Clear cache") { clearCache() }

                    Button("Cancel transfer", role: .destructive) {
                        offload.cancelOffload()
                    }
                    .disabled(!offload.isBusy)
                } header: {
                    Text("DashCam Studio")
                } footer: {
                    Text("Run DashCam Studio on your Mac. The switch only opens the link — nothing is ever uploaded on its own.\n\nOffload all videos moves everything and frees the phone once the Mac verifies each checksum. To send one clip, open it and tap Send to Studio; to send a few, use Library ▸ Select. Import brings back road features you labelled in Studio.\n\nClear cache deletes half-finished remuxes and stale temporary files. Your footage and telemetry are never touched.")
                }

                Section {
                    LabeledContent("Location", value: "Files ▸ On My iPhone ▸ Dash Cam ▸ Logs")
                    LabeledContent("Log files", value: diagnosticsSummary)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Errors and crash reports are written to the Logs folder on this device and are browsable in the Files app.")
                }

                Section {
                    Toggle("Simulate full disk", isOn: $simulateFullDisk)
                        .onChange(of: simulateFullDisk) {
                            vm.storage.simulatedFreeSpace = simulateFullDisk ? 0 : nil
                            vm.refreshCapacityWarning()
                            refreshStorageReadout()
                        }
                    Button("Simulate impact (auto-tag)") {
                        vm.motion.simulateImpact()
                    }
                    .disabled(!vm.capture.isRecording)
                    Button(generatingSample ? "Generating sample clip…" : "Add sample clip to Loop") {
                        generatingSample = true
                        Task {
                            await DebugSampleClip.generate(
                                storage: vm.storage,
                                tagStore: vm.tagStore,
                                context: context,
                                tagged: false
                            )
                            generatingSample = false
                            refreshStorageReadout()
                        }
                    }
                    .disabled(generatingSample)
                    Button("Add tagged sample clip") {
                        generatingSample = true
                        Task {
                            await DebugSampleClip.generate(
                                storage: vm.storage,
                                tagStore: vm.tagStore,
                                context: context,
                                tagged: true
                            )
                            generatingSample = false
                            refreshStorageReadout()
                        }
                    }
                    .disabled(generatingSample)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Full-disk simulation clamps reported free space to zero so loop pruning and the stop-recording path can be tested. Sample clips exercise the library without a camera.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                simulateFullDisk = vm.storage.simulatedFreeSpace != nil
                refreshStorageReadout()
            }
            .sheet(isPresented: $showTrainingMode) {
                TrainingModeView()
            }
            .sheet(isPresented: $showFieldTag) {
                FieldTagView()
            }
            .sheet(isPresented: $showRoadMemory) {
                RoadMemoryView()
            }
            .alert(
                "Cache cleared",
                isPresented: Binding(
                    get: { cacheMessage != nil },
                    set: { if !$0 { cacheMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cacheMessage ?? "")
            }
            .alert("Offload all videos?", isPresented: $confirmOffloadEverything) {
                Button("Cancel", role: .cancel) { }
                Button("Offload All", role: .destructive) { offload.startOffload() }
            } message: {
                Text("This uploads \(offloadableSummary) to your Mac and removes each file from the phone once the Mac verifies it.")
            }
        }
    }

    private func clearCache() {
        let freed = vm.storage.clearCaches()
        library.thumbnails.clearCache()
        refreshStorageReadout()
        cacheMessage = freed > 0
            ? "Cleared \(Format.fileSize(freed)) of temporary files."
            : "Nothing to clear — no temporary files were left behind."
    }

    /// What "everything" actually means right now, so neither confirmation
    /// is an abstract question.
    private var offloadableSummary: String {
        let clips = (try? context.fetch(FetchDescriptor<ClipSegment>())) ?? []
        let bytes = clips.reduce(Int64(0)) { $0 + $1.fileSize }
        guard !clips.isEmpty else { return "nothing right now" }
        return "\(clips.count) clip\(clips.count == 1 ? "" : "s"), \(Format.fileSize(bytes))"
    }

    private var otherResolution: VideoResolution {
        settings.resolution == .hd ? .uhd4k : .hd
    }

    private var offloadStatusText: String {
        switch offload.status {
        case .idle: return settings.studioConnectionEnabled ? "Off" : "Disconnected"
        case .searching: return "Looking for your Mac…"
        case .ready(let host): return "Connected (\(host))"
        case .offloading(let done, let total): return "Uploading \(done)/\(total)"
        case .finished(let clips, let bytes):
            return clips > 0 ? "Done — \(clips) clips (\(Format.fileSize(bytes)))" : "Nothing to offload"
        case .failed(let message): return message
        }
    }

    private var diagnosticsSummary: String {
        let summary = DiagLog.shared.logFileSummary()
        let size = Format.fileSize(summary.bytes)
        return summary.crashes > 0
            ? "\(summary.count) (\(size)), \(summary.crashes) crash report(s)"
            : "\(summary.count) (\(size))"
    }

    private var locationStatusText: String {
        switch vm.location.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        default: return "Not determined"
        }
    }

    private func capacityText(for resolution: VideoResolution) -> String {
        let minutes = vm.storage.estimatedLoopMinutes(resolution: resolution)
        if minutes >= 90 {
            return String(format: "~%.1f hours", minutes / 60)
        }
        return String(format: "~%.0f min", minutes)
    }

    private func refreshStorageReadout() {
        loopBytes = vm.storage.folderBytes(.loop)
        savedBytes = vm.storage.folderBytes(.saved)
        freeBytes = vm.storage.freeSpace()
    }
}
