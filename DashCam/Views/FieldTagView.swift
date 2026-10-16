import CoreLocation
import SwiftData
import SwiftUI

/// Walk up to a sign and pin it.
///
/// Tagging from a moving car is inherently loose: the fix is recorded at
/// whatever instant the camera read the sign, at speed, so the pin lands
/// wherever the car was — often tens of metres before the pole. Standing
/// still at the sign removes all of that. It also lets the phone average a
/// run of fixes instead of trusting one, which cancels the jitter that makes
/// a single stationary reading wander.
///
/// The saved feature is marked `manual`, which the recall logic treats as
/// authoritative — no second sighting needed before it's trusted.
struct FieldTagView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var roadMemory: RoadMemory
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @StateObject private var surveyor = FieldSurveyor()

    @State private var type: RoadFeatureType = .stop
    @State private var value = ""
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    signPreview
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } header: {
                    Text("What are you standing at?")
                }

                Section {
                    Picker("Sign", selection: $type) {
                        ForEach(RoadFeatureType.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                    if type.usesNumericValue {
                        TextField("Speed (mph)", text: $value)
                            .keyboardType(.numberPad)
                    } else if type == .city {
                        TextField("City name", text: $value)
                    }
                }

                Section {
                    fixReadout
                    if surveyor.isSampling {
                        ProgressView(value: surveyor.progress)
                        Button("Stop early", role: .cancel) { surveyor.finish() }
                    } else {
                        Button {
                            surveyor.start()
                        } label: {
                            Label(surveyor.result == nil ? "Take a fix" : "Take another fix",
                                  systemImage: "location.fill")
                        }
                    }
                } header: {
                    Text("Position")
                } footer: {
                    Text("Stand at the sign, facing the way traffic travels past it, and hold still. The phone averages \(FieldSurveyor.targetSamples) fixes over about \(Int(FieldSurveyor.targetSamples)) seconds — averaging cancels jitter but not a bad fix, so wait for the accuracy to settle before saving.")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label("Save this sign", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(surveyor.result == nil)
                } footer: {
                    Text("Saved by hand, so the phone trusts it immediately — a camera-detected sign needs two sightings before it's used.")
                }
            }
            .navigationTitle("Tag a sign here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { surveyor.begin() }
            .onDisappear { surveyor.end() }
            .alert(
                "Saved",
                isPresented: Binding(
                    get: { savedMessage != nil },
                    set: { if !$0 { savedMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(savedMessage ?? "")
            }
        }
    }

    /// The real sign, so there's no doubt which one is being placed.
    @ViewBuilder
    private var signPreview: some View {
        switch type {
        case .stop: StopSignView(size: 84)
        case .yield: YieldSignView(size: 88)
        case .doNotEnter: DoNotEnterSignView(size: 80)
        case .railroad: RailroadSignView(size: 80)
        case .pedestrianCrossing: PedestrianCrossingSignView(size: 80)
        case .speedLimit: SpeedLimitSignView(limit: Int(value) ?? 25)
        case .school: SchoolCrossingSignView(speed: Int(value))
        case .hump: SpeedHumpSignView(speed: Int(value))
        case .hospital: HospitalSignView()
        case .bike: BikeLaneSignView()
        case .lowClearance:
            ClearanceSignView(clearance: Clearance(feet: Int(value) ?? 13, inches: 0))
        case .city, .fireStation:
            Label(type.label, systemImage: type.systemImage)
                .font(.title3.bold())
        }
    }

    @ViewBuilder
    private var fixReadout: some View {
        if let result = surveyor.result {
            LabeledContent("Accuracy", value: Format.feet(result.accuracyMeters))
            LabeledContent("Spread", value: Format.feet(result.spreadMeters))
            LabeledContent("Facing", value: headingText(result.heading))
            LabeledContent("Position", value: String(format: "%.6f, %.6f", result.latitude, result.longitude))
        } else if surveyor.isSampling {
            LabeledContent("Collecting", value: "\(surveyor.sampleCount) of \(FieldSurveyor.targetSamples)")
        } else {
            Text("No fix yet")
                .foregroundStyle(.secondary)
        }
    }

    private func headingText(_ heading: Double) -> String {
        guard heading >= 0 else { return "Unknown — point the phone the way traffic goes" }
        return "\(Format.cardinal(heading)) \(Int(heading.rounded()))°"
    }

    private func save() {
        guard let result = surveyor.result else { return }
        guard result.heading >= 0 else {
            savedMessage = "No compass heading yet. A sign only applies to one direction of travel, so point the phone the way traffic passes it and take the fix again."
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        _ = roadMemory.addManual(
            type: type,
            value: trimmed.isEmpty ? nil : trimmed,
            latitude: result.latitude,
            longitude: result.longitude,
            heading: result.heading
        )
        DiagLog.shared.info(
            "Field tag: \(type.rawValue) at \(result.latitude),\(result.longitude) "
            + "heading \(Int(result.heading))° ±\(Int(result.accuracyMeters))m"
        )
        Haptics.tagConfirmed()
        savedMessage = "\(type.label) pinned at ±\(Format.feet(result.accuracyMeters)), facing \(Format.cardinal(result.heading)). It will show on your next drive through here."
        value = ""
    }
}

/// Collects a burst of stationary GPS fixes and averages them.
///
/// A single fix jitters by several metres from one second to the next even
/// standing still. Averaging a run of them removes that jitter. It does NOT
/// remove a systematic offset — multipath off a building biases every fix
/// the same way — which is why the spread between fixes is reported next to
/// the claimed accuracy: if they disagree, the fix is worse than it says.
@MainActor
final class FieldSurveyor: NSObject, ObservableObject {
    struct Result {
        var latitude: Double
        var longitude: Double
        var heading: Double
        /// Best reported horizontal accuracy across the burst, in metres.
        var accuracyMeters: Double
        /// How far the individual fixes scattered from their mean, in metres.
        var spreadMeters: Double
    }

    static let targetSamples = 10

    @Published private(set) var isSampling = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var result: Result?

    var progress: Double {
        Double(sampleCount) / Double(Self.targetSamples)
    }

    private let manager = CLLocationManager()
    private var collected: [CLLocation] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Powers up location and heading for the screen.
    func begin() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func end() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func start() {
        collected.removeAll()
        sampleCount = 0
        result = nil
        isSampling = true
    }

    func finish() {
        isSampling = false
        guard !collected.isEmpty else { return }

        // Weight each fix by how good it claims to be, so a bad one in the
        // burst can't drag the answer.
        var weightSum = 0.0
        var latSum = 0.0
        var lonSum = 0.0
        var best = Double.greatestFiniteMagnitude
        for fix in collected {
            let accuracy = max(1, fix.horizontalAccuracy)
            let weight = 1 / (accuracy * accuracy)
            weightSum += weight
            latSum += fix.coordinate.latitude * weight
            lonSum += fix.coordinate.longitude * weight
            best = min(best, accuracy)
        }
        guard weightSum > 0 else { return }
        let latitude = latSum / weightSum
        let longitude = lonSum / weightSum

        // RMS distance of the individual fixes from the averaged point.
        let spread = (collected.reduce(0.0) { total, fix in
            let metres = GeoMatch.distance(
                fromLat: latitude, fromLon: longitude,
                toLat: fix.coordinate.latitude, toLon: fix.coordinate.longitude
            )
            return total + metres * metres
        } / Double(collected.count)).squareRoot()

        result = Result(
            latitude: latitude,
            longitude: longitude,
            heading: currentHeading,
            accuracyMeters: best,
            spreadMeters: spread
        )
    }

    private var currentHeading: Double = -1
}

extension FieldSurveyor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.filter { $0.horizontalAccuracy > 0 }
        guard !fixes.isEmpty else { return }
        Task { @MainActor in
            guard self.isSampling else { return }
            self.collected.append(contentsOf: fixes)
            self.sampleCount = self.collected.count
            if self.sampleCount >= Self.targetSamples {
                self.finish()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.currentHeading = heading
        }
    }
}
