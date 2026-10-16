import SwiftUI

/// Road Memory editor: review what the app has learned, correct it, disable
/// it, or hand-place features the camera will never read.
struct RoadMemoryView: View {
    @EnvironmentObject private var memory: RoadMemory
    @EnvironmentObject private var vm: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var features: [RoadFeature] = []
    @State private var filter: RoadFeatureType?
    @State private var editing: RoadFeature?
    @State private var editValue = ""
    @State private var showAdd = false
    @State private var confirmDeleteAll = false

    private var currentFix: (lat: Double, lon: Double, heading: Double)? {
        guard let lat = vm.location.latitude, let lon = vm.location.longitude else { return nil }
        let heading = vm.location.headingDegrees >= 0
            ? vm.location.headingDegrees
            : (vm.motionHeading ?? -1)
        return (lat, lon, heading)
    }

    private var filtered: [RoadFeature] {
        let list = filter.map { type in features.filter { $0.type == type } } ?? features
        guard let fix = currentFix else { return list }
        return list.sorted {
            memory.distance(from: fix.lat, fix.lon, to: $0)
                < memory.distance(from: fix.lat, fix.lon, to: $1)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if features.isEmpty {
                    ContentUnavailableView(
                        "Nothing remembered yet",
                        systemImage: "map",
                        description: Text("Signs the camera confirms while you drive are remembered here, and shown from memory on later passes. You can also add one at your current location.")
                    )
                } else {
                    List {
                        Section {
                            Picker("Show", selection: $filter) {
                                Text("All").tag(RoadFeatureType?.none)
                                ForEach(RoadFeatureType.allCases) { type in
                                    Text(type.label).tag(RoadFeatureType?.some(type))
                                }
                            }
                        }
                        ForEach(filtered) { feature in
                            row(feature)
                        }
                        // A list row, not a .bottomBar item — bottom-bar
                        // buttons collapse to zero width in landscape sheets.
                        Section {
                            Button("Forget everything", role: .destructive) {
                                confirmDeleteAll = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("Road Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add here", systemImage: "plus.circle")
                    }
                    .disabled(currentFix == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { reload() }
            .sheet(isPresented: $showAdd) {
                AddFeatureView(fix: currentFix) { type, value in
                    if let fix = currentFix {
                        memory.addManual(
                            type: type, value: value,
                            latitude: fix.lat, longitude: fix.lon, heading: fix.heading
                        )
                        reload()
                    }
                }
            }
            .alert("Edit value", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("Value", text: $editValue)
                    .keyboardType(.numbersAndPunctuation)
                Button("Save") {
                    if let feature = editing {
                        memory.update(feature, value: editValue.isEmpty ? nil : editValue)
                        reload()
                    }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                Text(editing?.type.usesNumericValue == true
                     ? "Speed in \(vm.settings.speedUnit.label)"
                     : "Label shown on screen")
            }
            .alert("Forget every remembered feature?", isPresented: $confirmDeleteAll) {
                Button("Forget all", role: .destructive) {
                    memory.deleteAll()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears everything the app has learned. It will re-learn as you drive.")
            }
        }
    }

    private func row(_ feature: RoadFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feature.type.systemImage)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(feature.enabled ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(feature.type.label)
                        .font(.subheadline.bold())
                    if let value = feature.value {
                        Text(feature.type.usesNumericValue ? "\(value) \(vm.settings.speedUnit.label)" : value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let fix = currentFix {
                        Text(distanceText(memory.distance(from: fix.lat, fix.lon, to: feature)))
                    }
                    Text("\(Format.cardinal(degrees: feature.heading))-bound")
                    Text(feature.source == .manual ? "manual" : "seen \(feature.confirmCount)×")
                    if !feature.isTrusted {
                        Text("unconfirmed")
                            .foregroundStyle(.orange)
                    }
                    if !feature.enabled {
                        Text("off")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editValue = feature.value ?? ""
            editing = feature
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                memory.delete(feature)
                reload()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                memory.setEnabled(feature, !feature.enabled)
                reload()
            } label: {
                Label(feature.enabled ? "Disable" : "Enable",
                      systemImage: feature.enabled ? "eye.slash" : "eye")
            }
            .tint(.orange)
        }
    }

    private func distanceText(_ meters: Double) -> String {
        meters < 1000
            ? String(format: "%.0f m away", meters)
            : String(format: "%.1f km away", meters / 1000)
    }

    private func reload() {
        features = memory.allFeatures()
    }
}

/// Hand-place a feature at the current position and heading.
private struct AddFeatureView: View {
    let fix: (lat: Double, lon: Double, heading: Double)?
    let onAdd: (RoadFeatureType, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: RoadFeatureType = .speedLimit
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(RoadFeatureType.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                    TextField(type.usesNumericValue ? "Speed" : "Label (optional)", text: $value)
                        .keyboardType(type.usesNumericValue ? .numberPad : .default)
                } footer: {
                    if let fix {
                        Text("Saved at your current position, for travel heading \(Format.cardinal(degrees: fix.heading)) (\(Int(fix.heading))°). It will show on future passes in this direction.")
                    } else {
                        Text("Waiting for a GPS fix.")
                    }
                }
            }
            .navigationTitle("Add feature here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(type, value.isEmpty ? nil : value)
                        dismiss()
                    }
                    .disabled(fix == nil)
                }
            }
        }
    }
}
