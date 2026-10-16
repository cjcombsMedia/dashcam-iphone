import AVFoundation
import DashCamKit
import SwiftUI

/// The labelling workspace: play the clip, pause where something matters,
/// step frame-by-frame to place a box precisely.
///
/// The tool panel is a fixed pane, not a draggable split — it can't be
/// collapsed and lost.
struct LabelingView: View {
    @EnvironmentObject var model: AppModel
    let clip: Clip

    @State private var player = AVPlayer()
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var rate: Float = 1.0
    @State private var videoSize = CGSize(width: 1920, height: 1080)
    @State private var frameRate: Double = 30
    @State private var timeObserver: Any?
    @State private var selectedLabelID: UUID?
    @State private var activeClass: LabelClass?
    @State private var pendingValue = ""
    @State private var sidecar: TelemetrySidecar?
    @State private var panel: Panel = .detections
    @State private var correcting: PhoneDetection?
    @State private var correctionClass = ""
    @State private var correctionValue = ""
    /// Redraw the phone's live screen on top of the video. On by default —
    /// reviewing a detection means seeing what the driver saw.
    @AppStorage("studio.showLiveOverlay") private var showLiveOverlay = true
    /// Which country's signs the palette offers.
    @AppStorage("studio.labelCountry") private var labelCountry: SignRegion = .both
    /// Sections the user has collapsed, persisted as a delimited string
    /// because AppStorage can't hold a Set.
    @AppStorage("studio.collapsedGroups") private var collapsedGroupsRaw = ""
    /// Sections explicitly opened this session, so an open section stays open.
    @State private var expandedOverride: [String: Bool] = [:]

    private enum Panel: String, CaseIterable {
        case detections = "Detections"
        case classes = "Label"
    }

    /// Labels shown on the current frame — a window, so a box placed at
    /// 12.03 s is still visible at 12.10 s.
    private var frameLabels: [FrameLabel] {
        model.labels(near: time, tolerance: 0.35)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VideoBoxCanvas(
                    player: player,
                    videoSize: videoSize,
                    labels: frameLabels,
                    classes: model.classes,
                    selectedLabelID: $selectedLabelID,
                    activeClass: activeClass,
                    onCreate: createLabel,
                    onUpdate: updateLabel,
                    onChangeClass: changeClass,
                    onDelete: { id in
                        model.deleteLabel(id: id)
                        if selectedLabelID == id { selectedLabelID = nil }
                    },
                    onDeselect: { deselectAll() }
                )
                .overlay {
                    if showLiveOverlay {
                        LiveOverlayView(
                            snapshot: currentSnapshot,
                            sample: currentSample,
                            emergencyBox: currentEmergencyBox,
                            videoSize: videoSize,
                            timestamp: sidecar.map { $0.startedAt.addingTimeInterval(time) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                transportBar
            }
            .frame(minWidth: 380, maxWidth: .infinity)

            Divider()

            inspector
                .frame(width: 300)
                .layoutPriority(1)
        }
        .sheet(item: $correcting) { detection in
            correctionSheet(detection)
        }
        // Esc is the universal "stop what I'm doing" on a Mac.
        .onExitCommand { deselectAll() }
        .task(id: clip.id) { await loadClip() }
        .onDisappear {
            player.pause()
            removeObserver()
            model.saveLabels()
        }
    }

    // MARK: - Transport

    private var transportBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(timeText(time))
                    .font(.system(.body, design: .monospaced))
                Slider(
                    value: Binding(
                        get: { time },
                        set: { newValue in
                            time = newValue
                            seek(to: newValue)
                        }
                    ),
                    in: 0...max(duration, 0.1)
                )
                Text(timeText(duration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 26)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (Space)")

                Picker("", selection: $rate) {
                    Text("0.5×").tag(Float(0.5))
                    Text("1×").tag(Float(1.0))
                    Text("2×").tag(Float(2.0))
                    Text("4×").tag(Float(4.0))
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: rate) { _, newValue in
                    if isPlaying { player.rate = newValue }
                }

                Divider().frame(height: 18)

                Button { step(by: -10) } label: { Image(systemName: "gobackward") }
                    .help("Back 10 frames")
                Button { step(by: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous frame (←)")
                Button { step(by: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next frame (→)")
                Button { step(by: 10) } label: { Image(systemName: "goforward") }
                    .help("Forward 10 frames")

                Divider().frame(height: 18)

                Button { jumpToNextLabelled() } label: {
                    Image(systemName: "chevron.right.2")
                }
                .disabled(model.labels.labels.isEmpty)
                .help("Jump to next labelled frame")

                Divider().frame(height: 18)

                Toggle(isOn: $showLiveOverlay) {
                    Image(systemName: showLiveOverlay ? "eye.fill" : "eye.slash")
                }
                .toggleStyle(.button)
                .keyboardShortcut("o", modifiers: [])
                .disabled(sidecar?.overlaySnapshots?.isEmpty ?? true)
                .help(sidecar?.overlaySnapshots?.isEmpty ?? true
                      ? "This clip has no recorded screen data — it predates overlay capture"
                      : "Show what the phone displayed live (O)")

                Spacer()

                if let sample = currentSample {
                    telemetryReadout(sample)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.bar)
    }

    private func telemetryReadout(_ sample: TelemetrySample) -> some View {
        HStack(spacing: 10) {
            if let speed = sample.speedMPS {
                Label(String(format: "%.0f mph", speed * 2.23694), systemImage: "speedometer")
            }
            if let heading = sample.headingDegrees, heading >= 0 {
                Label(String(format: "%.0f°", heading), systemImage: "location.north.line")
            }
            Image(systemName: sample.latitude != nil ? "mappin.and.ellipse" : "mappin.slash")
                .foregroundStyle(sample.latitude != nil ? .green : .orange)
                .help(sample.latitude != nil
                      ? "GPS fix here — sign labels become road memory"
                      : "No GPS at this moment — labels train the detector only")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Inspector (always present)

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                if model.hasUnsavedChanges {
                    Label("Unsaved", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(10)

            Picker("", selection: $panel) {
                ForEach(Panel.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // Selected-box editor sits at the TOP so it's always visible —
            // click any box (or right-click it) to correct a wrong label.
            if let selected = frameLabels.first(where: { $0.id == selectedLabelID }) {
                selectedLabelEditor(selected)
                Divider()
            }

            if panel == .detections {
                detectionsPanel
            } else {
                labelPanel
            }
        }
    }

    /// What the phone actually showed during the drive — confirm it, correct
    /// it, or reject it as a false positive.
    private var detectionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(model.detections.count) shown on this drive")
                    Spacer()
                    Text("✓\(model.confirmedCount)  ✕\(model.rejectedCount)")
                        .foregroundStyle(.secondary)
                }
                // Reviewing is the work; show how much of it is done.
                let reviewed = model.reviewedCount
                let total = max(model.detections.count, 1)
                ProgressView(value: Double(reviewed), total: Double(total))
                Text("\(reviewed) of \(model.detections.count) reviewed"
                     + (reviewed < model.detections.count
                        ? " — \(model.detections.count - reviewed) left"
                        : " — ready to send"))
                    .foregroundStyle(reviewed == model.detections.count ? .green : .secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if model.detections.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No detections recorded for this clip.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(model.detections) { detection in
                        detectionRow(detection)
                    }
                }
            }
        }
    }

    private func detectionRow(_ detection: PhoneDetection) -> some View {
        let verdict = model.verdict(for: detection)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let verdict {
                    Image(systemName: verdict == .rejected
                          ? "xmark.circle.fill"
                          : (verdict == .corrected ? "pencil.circle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(verdict == .rejected ? .red : .green)
                }
                Text(detection.display)
                    .font(.callout.bold())
                    .lineLimit(1)
                if let value = detection.value {
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(timeText(detection.time)) {
                    seek(to: detection.time)
                    time = detection.time
                    if isPlaying { togglePlay() }
                }
                .buttonStyle(.link)
                .font(.caption.monospaced())
            }

            HStack(spacing: 6) {
                // The chosen verdict is filled, the others outlined, so the
                // panel always says what you decided at a glance.
                Button {
                    model.setVerdict(.confirmed, for: detection)
                } label: {
                    Label("Correct", systemImage: "checkmark")
                }
                .buttonStyle(verdict == .confirmed ? AnyPrimitiveButtonStyle(.borderedProminent)
                                                   : AnyPrimitiveButtonStyle(.bordered))
                .tint(.green)

                Button {
                    correcting = detection
                    correctionClass = detection.className
                    correctionValue = detection.value ?? ""
                } label: {
                    Label("Fix", systemImage: "pencil")
                }
                .buttonStyle(verdict == .corrected ? AnyPrimitiveButtonStyle(.borderedProminent)
                                                   : AnyPrimitiveButtonStyle(.bordered))
                .tint(.orange)

                Button {
                    model.setVerdict(.rejected, for: detection)
                } label: {
                    Label("Wrong", systemImage: "xmark")
                }
                .buttonStyle(verdict == .rejected ? AnyPrimitiveButtonStyle(.borderedProminent)
                                                   : AnyPrimitiveButtonStyle(.bordered))
                .tint(.red)
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)

            if let verdict {
                Text(verdictExplanation(verdict, detection))
                    .font(.caption2)
                    .foregroundStyle(verdict == .rejected ? .red : .green)
            }
        }
        .padding(.vertical, 3)
        .opacity(verdict == .rejected ? 0.55 : 1)
    }

    /// Says what this verdict will actually do, so the consequence of a
    /// click is never a mystery.
    private func verdictExplanation(_ verdict: DetectionVerdict, _ detection: PhoneDetection) -> String {
        switch verdict {
        case .confirmed:
            return "Confirmed — will be sent to the phone as a place it should remember"
        case .corrected:
            return "Corrected — the phone will learn the corrected value here"
        case .rejected:
            return "Rejected — never sent to the phone, and kept as a false-positive example"
        }
    }

    /// Which country's signage to offer. Mexican and US signs share almost
    /// no legends, so showing both at once doubles the list for no gain.
    private var countryPicker: some View {
        Picker("", selection: $labelCountry) {
            Text("🌎 All").tag(SignRegion.both)
            Text("🇺🇸 USA").tag(SignRegion.unitedStates)
            Text("🇲🇽 Mexico").tag(SignRegion.mexico)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .help("Filters the palette to the signage used in that country")
    }

    private func classRow(_ item: LabelClass) -> some View {
        let isActive = activeClass?.name == item.name
        return Button {
            // Clicking the active class again clears it. Without this the
            // palette is one-way: once armed you can never put the tool down.
            if isActive {
                activeClass = nil
            } else {
                activeClass = item
                applyClassToSelection(item)
            }
        } label: {
            HStack(spacing: 6) {
                // The sign itself, not a colour chip — shape is how you
                // recognise a sign at a glance, on the road and in a list.
                SignThumbnail(item: item, size: 22)
                    .frame(width: 24, height: 24)
                Text(item.display)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Only flag the country-specific ones — marking everything
                // would be noise.
                if item.region != .both {
                    Text(item.region.flag).font(.caption2)
                }
                Spacer(minLength: 4)
                if isActive {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 1)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "Click again to put this class down" : "Arm this class, then drag a box")
    }

    /// Section open/closed state, remembered between launches. Signs is open
    /// by default; everything else starts collapsed so the palette fits on
    /// screen without scrolling.
    private func expansion(for group: String) -> Binding<Bool> {
        Binding(
            get: { collapsedGroups.contains(group) ? false : defaultExpanded(group) },
            set: { isOpen in
                var groups = collapsedGroups
                if isOpen { groups.remove(group) } else { groups.insert(group) }
                collapsedGroups = groups
                expandedOverride[group] = isOpen
            }
        )
    }

    private func defaultExpanded(_ group: String) -> Bool {
        expandedOverride[group] ?? (group == "Signs")
    }

    private var collapsedGroups: Set<String> {
        get { Set(collapsedGroupsRaw.split(separator: "\u{1}").map(String.init)) }
        nonmutating set { collapsedGroupsRaw = newValue.sorted().joined(separator: "\u{1}") }
    }

    private var labelPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(activeClass == nil
                     ? "Pick a class, then drag a box on the video"
                     : "Drag a box on the video to add “\(activeClass!.display)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if hasSelection {
                    Button {
                        deselectAll()
                    } label: {
                        Label("Deselect", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Put the class down and deselect the box (Esc)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            countryPicker

            List {
                ForEach(groupedClasses, id: \.key) { group, items in
                    DisclosureGroup(isExpanded: expansion(for: group)) {
                        ForEach(items) { item in
                            classRow(item)
                        }
                    } label: {
                        HStack {
                            Text(group).font(.caption.bold())
                            Spacer()
                            Text("\(items.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("\(frameLabels.count) on this frame · \(model.labels.labels.count) in clip")
                if let saved = model.lastSavedAt {
                    Text("Saved \(saved.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(10)

            Button {
                model.saveLabels()
                // Saving ends the editing gesture — leaving a class armed
                // and a box selected invites the next click from drawing
                // something unintended.
                deselectAll()
            } label: {
                Label("Save clip labels", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .padding(10)
        }
    }

    /// Editing panel for the selected box — change its class, set a value,
    /// or delete it.
    private func selectedLabelEditor(_ label: FrameLabel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let current = model.labelClass(named: label.className) {
                    SignThumbnail(item: current, size: 26)
                        .frame(width: 28, height: 28)
                }
                Label("Selected box", systemImage: "square.dashed.inset.filled")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    selectedLabelID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Deselect")
            }

            Picker("Class", selection: Binding(
                get: { label.className },
                set: { newName in
                    if let item = model.labelClass(named: newName) {
                        changeClass(label.id, item)
                    }
                }
            )) {
                ForEach(groupedClasses, id: \.key) { group, items in
                    Section(group) {
                        ForEach(items) { item in
                            Label {
                                Text(item.display)
                            } icon: {
                                SignThumbnail(item: item, size: 16)
                            }
                            .tag(item.name)
                        }
                    }
                }
            }
            .labelsHidden()

            if model.labelClass(named: label.className)?.hasValue == true {
                TextField("Value (e.g. 45)", text: $pendingValue)
                    .textFieldStyle(.roundedBorder)
                    // Return commits and moves on, so you can keep labelling.
                    .onSubmit { finishEditing(label) }
            }

            HStack(spacing: 8) {
                Button {
                    finishEditing(label)
                } label: {
                    Label("Save tag", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])

                Button(role: .destructive) {
                    model.deleteLabel(id: label.id)
                    selectedLabelID = nil
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this box")
            }

            // Precise positioning without the mouse.
            HStack(spacing: 6) {
                Text("Nudge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button { nudge(label, dx: -0.004, dy: 0) } label: { Image(systemName: "arrow.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button { nudge(label, dx: 0.004, dy: 0) } label: { Image(systemName: "arrow.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Button { nudge(label, dx: 0, dy: -0.006) } label: { Image(systemName: "arrow.up") }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button { nudge(label, dx: 0, dy: 0.006) } label: { Image(systemName: "arrow.down") }
                    .keyboardShortcut(.downArrow, modifiers: .option)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("at \(timeText(label.time)) · drag the box to move · ⌥arrows to nudge")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .onAppear { pendingValue = label.value ?? "" }
        .onChange(of: label.id) { _, _ in pendingValue = label.value ?? "" }
        .onExitCommand { finishEditing(label) }
    }

    /// True when anything is armed or selected.
    private var hasSelection: Bool {
        activeClass != nil || selectedLabelID != nil
    }

    /// Puts the class down and deselects the box. One action, because from
    /// the owner's side they're the same thing: "stop editing".
    private func deselectAll() {
        if let selected = model.labels.labels.first(where: { $0.id == selectedLabelID }) {
            commitValue(selected)      // never lose a half-typed value
        }
        activeClass = nil
        selectedLabelID = nil
    }

    /// Commits the value and closes the panel so the next box on this frame
    /// can be selected. Clip-wide saving stays on "Save clip labels".
    private func finishEditing(_ label: FrameLabel) {
        commitValue(label)
        selectedLabelID = nil
    }

    /// Correcting one of the phone's detections: what it should have said.
    private func correctionSheet(_ detection: PhoneDetection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct this detection")
                .font(.headline)
            Text("The phone showed “\(detection.display)\(detection.value.map { " \($0)" } ?? "")” at \(timeText(detection.time)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Should have been", selection: $correctionClass) {
                ForEach(groupedClasses, id: \.key) { group, items in
                    Section(group) {
                        ForEach(items) { item in
                            Label {
                                Text(item.display)
                            } icon: {
                                SignThumbnail(item: item, size: 16)
                            }
                            .tag(item.name)
                        }
                    }
                }
            }

            if model.labelClass(named: correctionClass)?.hasValue == true {
                TextField("Value (e.g. 25)", text: $correctionValue)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { correcting = nil }
                Spacer()
                Button("Save correction") {
                    model.setVerdict(
                        .corrected, for: detection,
                        className: correctionClass,
                        value: correctionValue.isEmpty ? nil : correctionValue
                    )
                    correcting = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    /// Moves a box by a fraction of the frame, clamped inside it.
    private func nudge(_ label: FrameLabel, dx: Double, dy: Double) {
        guard var updated = model.labels.labels.first(where: { $0.id == label.id }) else { return }
        updated.x = min(max(0, updated.x + dx), 1 - updated.width)
        updated.y = min(max(0, updated.y + dy), 1 - updated.height)
        model.updateLabel(updated)
    }

    private func changeClass(_ id: UUID, _ item: LabelClass) {
        guard var label = model.labels.labels.first(where: { $0.id == id }) else { return }
        label.className = item.name
        // A class that carries no value shouldn't keep a stale one.
        if !item.hasValue { label.value = nil }
        model.updateLabel(label)
        activeClass = item
        pendingValue = label.value ?? ""
    }

    /// Groups in the order you meet them on the road, not alphabetically —
    /// alphabetical puts "Guide" above "Signals" and buries the classes used
    /// most. "Ignore" sits last because it's the least-used and the most
    /// dangerous to click by accident.
    private static let groupOrder = [
        "Signs", "Signals", "Routes", "Guide", "Services", "Transit",
        "Landmarks", "Lane & clearance", "Road users", "Obstacles",
        "Surface", "Ignore",
    ]

    /// Classes for the country being labelled, grouped and ordered.
    private var groupedClasses: [(key: String, value: [LabelClass])] {
        let visible = model.classes.filter { $0.region.applies(to: labelCountry) }
        return Dictionary(grouping: visible, by: \.group)
            .map { (key: $0.key, value: $0.value.sorted { $0.display < $1.display }) }
            .sorted { first, second in
                let a = Self.groupOrder.firstIndex(of: first.key) ?? Int.max
                let b = Self.groupOrder.firstIndex(of: second.key) ?? Int.max
                return a == b ? first.key < second.key : a < b
            }
    }

    // MARK: - Editing

    private func createLabel(_ rect: CGRect) {
        guard let activeClass else { return }
        // Pause on the frame being labelled so the box lands where you drew it.
        if isPlaying { togglePlay() }
        let label = FrameLabel(
            time: time,
            className: activeClass.name,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height
        )
        model.addLabel(label)
        selectedLabelID = label.id
        pendingValue = ""
    }

    private func updateLabel(_ id: UUID, _ rect: CGRect) {
        guard var label = model.labels.labels.first(where: { $0.id == id }) else { return }
        label.x = rect.minX
        label.y = rect.minY
        label.width = rect.width
        label.height = rect.height
        model.updateLabel(label)
    }

    private func applyClassToSelection(_ item: LabelClass) {
        guard let id = selectedLabelID,
              var label = model.labels.labels.first(where: { $0.id == id }) else { return }
        label.className = item.name
        model.updateLabel(label)
    }

    private func commitValue(_ label: FrameLabel) {
        var updated = label
        updated.value = pendingValue.isEmpty ? nil : pendingValue
        model.updateLabel(updated)
    }

    // MARK: - Playback

    private func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.05 { seek(to: 0) }
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    private func step(by frames: Int) {
        if isPlaying { togglePlay() }
        player.currentItem?.step(byCount: frames)
        // step() moves the item; read the new position back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            time = player.currentTime().seconds
        }
    }

    private func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func jumpToNextLabelled() {
        let times = model.labels.labels.map(\.time).sorted()
        guard let next = times.first(where: { $0 > time + 0.05 }) ?? times.first else { return }
        if isPlaying { togglePlay() }
        time = next
        seek(to: next)
    }

    private var currentSample: TelemetrySample? {
        sidecar?.sample(atOffset: time)
    }

    private var currentSnapshot: OverlaySnapshot? { sidecar?.screen(atOffset: time) }

    private var currentEmergencyBox: [Double]? { sidecar?.emergencyBox(atOffset: time) }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let total = Int(seconds)
        return String(format: "%d:%02d.%02d", total / 60, total % 60,
                      Int((seconds - Double(total)) * 100))
    }

    // MARK: - Loading

    private func loadClip() async {
        removeObserver()
        player.pause()
        isPlaying = false
        selectedLabelID = nil
        time = 0
        sidecar = clip.loadSidecar()

        let asset = AVURLAsset(url: clip.url)
        if let loaded = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(loaded)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let displayed = CGRect(origin: .zero, size: size).applying(transform)
                videoSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                frameRate = Double(rate)
            }
        }

        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause

        let observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { current in
            time = current.seconds
            if duration > 0, current.seconds >= duration - 0.05 {
                isPlaying = false
            }
        }
        timeObserver = observer
    }

    private func removeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}
