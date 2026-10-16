import DashCamKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showClasses = false
    @State private var showLog = false
    @State private var showTraining = false
    @State private var pendingDelete: Clip?
    @State private var pendingVideoDelete: Clip?

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 260)
        } detail: {
            if let clip = model.selectedClip {
                LabelingView(clip: clip)
            } else {
                welcome
            }
        }
        // No window toolbar at all: macOS collapses toolbar items into a
        // ">>" overflow menu whenever the window narrows, which is exactly
        // the fly-out we're getting rid of. These live in the sidebar
        // instead, where they are always visible at any window size.
        .sheet(isPresented: $showClasses) {
            ClassesView().environmentObject(model)
        }
        .sheet(isPresented: $showTraining) {
            TrainingConsoleView().environmentObject(model)
        }
        .inspector(isPresented: $showLog) {
            transferLog
                .inspectorColumnWidth(min: 260, ideal: 320)
        }
        .alert(
            "DashCam Studio",
            isPresented: Binding(
                get: { model.statusMessage != nil },
                set: { if !$0 { model.statusMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.statusMessage ?? "")
        }
        .alert("Free up disk space?", isPresented: $model.offerCleanup) {
            Button("Delete videos, keep labels", role: .destructive) {
                model.deleteClipVideos(model.labelledClipsSafeToDelete, keepSidecars: true)
            }
            Button("Delete videos and telemetry", role: .destructive) {
                model.deleteClipVideos(model.labelledClipsSafeToDelete, keepSidecars: false)
            }
            Button("Keep everything", role: .cancel) {}
        } message: {
            Text(cleanupMessage)
        }
        .overlay {
            if model.busy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Working…")
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            clipList
            Divider()
            actionBar
        }
    }

    /// Always-visible controls. Two columns of equal-width buttons so the
    /// pane reads as one block rather than a ragged row that can overflow.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.receiving ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(model.receiving ? "Receiving from iPhone" : "Receiver off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                model.receiving ? model.stopReceiver() : model.startReceiver()
            } label: {
                Label(model.receiving ? "Stop receiver" : "Start receiver",
                      systemImage: model.receiving ? "stop.circle.fill" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(model.receiving ? .red : .green)

            Button { showTraining = true } label: {
                Label("Model Training", systemImage: "brain")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("See every correction, every message to the phone, and what it accepted")

            Text("Actions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                actionButton("Send to phone", "iphone.and.arrow.right.inward",
                             help: "Export road memory — the phone picks it up on the next connect",
                             disabled: model.busy) { model.exportRoadMemory() }

                actionButton("Training data", "square.stack.3d.up",
                             help: "Export a Create ML dataset from every label you've drawn",
                             disabled: model.busy) { model.exportTrainingDataset() }

                actionButton("Classes", "tag",
                             help: "Edit the label classes",
                             disabled: false) { showClasses = true }

                actionButton("Transfer log", "list.bullet.rectangle",
                             help: "Show what has arrived from the phone",
                             disabled: false) { showLog.toggle() }

                actionButton("Free space", "trash",
                             help: "Delete the videos of clips you've already labelled",
                             disabled: model.busy || model.labelledClipsSafeToDelete.isEmpty) {
                    model.offerCleanup = true
                }

                actionButton("Finder", "folder",
                             help: "Reveal the DashCam workspace in Finder",
                             disabled: false) { model.revealWorkspace() }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func actionButton(
        _ title: String, _ icon: String, help: String, disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .help(help)
        .disabled(disabled)
    }

    private var clipList: some View {
        List(selection: Binding(
            get: { model.selectedClip?.id },
            set: { id in model.select(model.clips.first { $0.id == id }) }
        )) {
            if !model.incoming.isEmpty {
                Section("Receiving now — \(model.incoming.count) file(s)") {
                    ForEach(model.incoming) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.fileName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: file.fraction)
                            Text("\(sizeText(file.received)) of \(sizeText(file.total)) · \(Int(file.fraction * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Inbox — \(model.clips.count) clip(s)") {
                ForEach(model.clips) { clip in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.fileName)
                                .font(.callout)
                                .lineLimit(1)
                            Text("\(clip.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(sizeText(clip.byteSize))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let count = model.labelCounts[clip.id], count > 0 {
                            Text("\(count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.25), in: Capsule())
                        }
                        if clip.sidecarURL == nil {
                            Image(systemName: "mappin.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("No telemetry sidecar — labels here can't become road memory")
                        }
                    }
                    .tag(clip.id)
                    .contextMenu {
                        Button("Open") { model.select(clip) }
                        Button("Reveal in Finder") { model.revealInFinder(clip) }
                        Divider()
                        Button("Delete video only") { pendingVideoDelete = clip }
                        Button("Delete clip and all its data…", role: .destructive) {
                            pendingDelete = clip
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { model.refreshClips() }
        .confirmationDialog(
            "Delete \(pendingDelete?.fileName ?? "")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                if let clip = pendingDelete { model.deleteClipCompletely(clip) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes the video, its telemetry, every label you drew and your detection review. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete the video for \(pendingVideoDelete?.fileName ?? "")?",
            isPresented: Binding(
                get: { pendingVideoDelete != nil },
                set: { if !$0 { pendingVideoDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete video", role: .destructive) {
                if let clip = pendingVideoDelete { model.deleteVideoOnly(clip) }
                pendingVideoDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingVideoDelete = nil }
        } message: {
            Text("Frees the disk space but keeps the telemetry, your labels and your review, so the road memory you built from it survives.")
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "car.side.and.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("DashCam Studio")
                .font(.largeTitle.bold())
            Text("""
            1. Start the receiver, then offload from the iPhone.
            2. Pick a clip and label what matters — signs, signals, bollards, bike-lane paint.
            3. Export road memory so the phone recalls those places, \
            and a training dataset to teach the detector.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)

            if model.clips.isEmpty {
                Button("Reveal workspace in Finder") { model.revealWorkspace() }
            }
        }
        .padding(40)
    }

    private var transferLog: some View {
        List(model.log.indices, id: \.self) { index in
            let event = model.log[index]
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: event.kind))
                    .foregroundStyle(color(for: event.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.message)
                        .font(.caption)
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.log.isEmpty {
                Text("No transfers yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for kind: OffloadReceiver.Event.Kind) -> String {
        switch kind {
        case .started: return "arrow.down.circle"
        case .received: return "checkmark.circle.fill"
        case .rejected: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for kind: OffloadReceiver.Event.Kind) -> Color {
        switch kind {
        case .received: return .green
        case .rejected, .failed: return .red
        case .started: return .blue
        case .info: return .secondary
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var cleanupMessage: String {
        let targets = model.labelledClipsSafeToDelete
        let bytes = targets.reduce(Int64(0)) { $0 + $1.byteSize }
        return """
        \(targets.count) labelled clip(s) using \(sizeText(bytes)).

        Your labels and exports are already saved separately, so deleting the \
        videos won't lose any tagging work. Keep the telemetry sidecars if you \
        might re-export road memory later; they're tiny.

        Unlabelled clips are never touched.
        """
    }
}

/// Add or remove label classes without touching code — new obstacle types
/// (bollards, barriers, painted markings) go here.
struct ClassesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var display = ""
    @State private var group = "Obstacles"
    @State private var color = "#FF9500"
    @State private var memoryType = ""
    @State private var hasValue = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Label classes").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            List {
                ForEach(model.classes) { item in
                    HStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: item.color))
                            .frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(item.display)
                            Text("\(item.name) · \(item.group)\(item.memoryType.map { " · memory: \($0)" } ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { model.deleteClasses(at: $0) }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add a class").font(.subheadline.bold())
                HStack {
                    TextField("machine_name", text: $name)
                    TextField("Display name", text: $display)
                }
                HStack {
                    TextField("Group", text: $group)
                    TextField("#RRGGBB", text: $color)
                    Toggle("Has value", isOn: $hasValue)
                }
                HStack {
                    TextField("Road-memory type (optional)", text: $memoryType)
                    Button("Add") {
                        guard !name.isEmpty else { return }
                        model.addClass(LabelClass(
                            name: name.replacingOccurrences(of: " ", with: "_").lowercased(),
                            display: display.isEmpty ? name : display,
                            color: color,
                            group: group.isEmpty ? "Other" : group,
                            memoryType: memoryType.isEmpty ? nil : memoryType,
                            hasValue: hasValue
                        ))
                        name = ""; display = ""; memoryType = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Road-memory type maps this class onto something the phone can recall: speedLimit, school, hump, hospital, bike, city, fireStation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            .padding()
        }
        .frame(width: 620, height: 560)
    }
}
