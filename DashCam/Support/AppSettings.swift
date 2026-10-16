import Foundation
import Combine

/// UserDefaults-backed settings shared by views and services.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// True on the one launch where auto-offload was found switched on and
    /// forced off. The offload service uses this to throw away any uploads
    /// that run had already queued in the background session.
    let didJustDisableAutoOffload: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Keys.speedUnit) ?? "") ?? .mph
        resolution = VideoResolution(rawValue: defaults.string(forKey: Keys.resolution) ?? "") ?? .hd
        sensitivity = AutoTagSensitivity(rawValue: defaults.string(forKey: Keys.sensitivity) ?? "") ?? .medium
        hudDimDelay = defaults.object(forKey: Keys.hudDimDelay) as? Double ?? 180
        segmentLength = defaults.object(forKey: Keys.segmentLength) as? Double ?? 180
        audioEnabled = defaults.object(forKey: Keys.audioEnabled) as? Bool ?? true
        showStartupReminder = defaults.object(forKey: Keys.showStartupReminder) as? Bool ?? true
        camera = CameraSelection(rawValue: defaults.string(forKey: Keys.camera) ?? "") ?? .wide
        alwaysLocation = defaults.object(forKey: Keys.alwaysLocation) as? Bool ?? true
        nightScreenMode = defaults.object(forKey: Keys.nightScreenMode) as? Bool ?? false
        emergencyLightDetection = defaults.object(forKey: Keys.emergencyLightDetection) as? Bool ?? true
        // One-time correction. An earlier build could leave auto-offload
        // switched on, which quietly uploaded every clip and filled the
        // Mac's disk. Offloading is opt-in only — force it off once, then
        // respect whatever the owner chooses from here on.
        if !defaults.bool(forKey: Keys.autoOffloadReset) {
            didJustDisableAutoOffload = defaults.object(forKey: Keys.autoOffload) as? Bool ?? false
            defaults.set(false, forKey: Keys.autoOffload)
            defaults.set(true, forKey: Keys.autoOffloadReset)
        } else {
            didJustDisableAutoOffload = false
        }
        studioConnectionEnabled = defaults.object(forKey: Keys.studioConnection) as? Bool ?? true
        vehicleHeightInches = defaults.object(forKey: Keys.vehicleHeight) as? Int ?? 0
        roadDetection = defaults.object(forKey: Keys.roadDetection) as? Bool ?? true
    }

    private enum Keys {
        static let speedUnit = "settings.speedUnit"
        static let resolution = "settings.resolution"
        static let sensitivity = "settings.autoTagSensitivity"
        static let hudDimDelay = "settings.hudDimDelay"
        static let segmentLength = "settings.segmentLength"
        static let audioEnabled = "settings.audioEnabled"
        static let showStartupReminder = "settings.showStartupReminder"
        static let camera = "settings.camera"
        static let alwaysLocation = "settings.alwaysLocation"
        static let nightScreenMode = "settings.nightScreenMode"
        static let emergencyLightDetection = "settings.emergencyLightDetection"
        static let studioConnection = "settings.studioConnection"
        static let vehicleHeight = "settings.vehicleHeightInches"
        /// Legacy. Auto-offload no longer exists; the key is still read once
        /// so an old install's queued uploads can be purged.
        static let autoOffload = "settings.autoOffload"
        static let autoOffloadReset = "settings.autoOffloadForcedOffOnce"
        static let roadDetection = "settings.roadDetection"
    }

    @Published var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Keys.speedUnit) }
    }

    /// Applies to the next session; the recording screen selector is disabled mid-session.
    @Published var resolution: VideoResolution {
        didSet { defaults.set(resolution.rawValue, forKey: Keys.resolution) }
    }

    @Published var sensitivity: AutoTagSensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity) }
    }

    /// Seconds of no interaction before the recording screen dims to the HUD.
    @Published var hudDimDelay: Double {
        didSet { defaults.set(hudDimDelay, forKey: Keys.hudDimDelay) }
    }

    /// Segment duration in seconds.
    @Published var segmentLength: Double {
        didSet { defaults.set(segmentLength, forKey: Keys.segmentLength) }
    }

    @Published var audioEnabled: Bool {
        didSet { defaults.set(audioEnabled, forKey: Keys.audioEnabled) }
    }

    @Published var showStartupReminder: Bool {
        didSet { defaults.set(showStartupReminder, forKey: Keys.showStartupReminder) }
    }

    /// Which camera records; locked while recording, like resolution.
    @Published var camera: CameraSelection {
        didSet { defaults.set(camera.rawValue, forKey: Keys.camera) }
    }

    /// When on, the app asks for Always location authorization so the fix
    /// survives without re-prompting on a dash-mounted phone.
    @Published var alwaysLocation: Bool {
        didSet { defaults.set(alwaysLocation, forKey: Keys.alwaysLocation) }
    }

    /// Manual day/night screen mode: day = 90% brightness, night = very low.
    @Published var nightScreenMode: Bool {
        didSet { defaults.set(nightScreenMode, forKey: Keys.nightScreenMode) }
    }

    /// On-device red/blue strobe detection that auto-tags emergency vehicles.
    @Published var emergencyLightDetection: Bool {
        didSet { defaults.set(emergencyLightDetection, forKey: Keys.emergencyLightDetection) }
    }

    /// Vehicle height in inches, 0 when not set. A posted clearance at or
    /// below this turns the sign red — the difference between a warning and
    /// a wrecked roof.
    @Published var vehicleHeightInches: Int {
        didSet { defaults.set(vehicleHeightInches, forKey: Keys.vehicleHeight) }
    }

    /// Whether the phone keeps a link open to DashCam Studio. On its own it
    /// uploads nothing — it only makes the Mac reachable so clips can be
    /// sent by hand. (Automatic offloading was removed entirely; it filled
    /// the Mac's disk without asking.)
    @Published var studioConnectionEnabled: Bool {
        didSet { defaults.set(studioConnectionEnabled, forKey: Keys.studioConnection) }
    }

    /// On-device recognition of signs, traffic signals, cyclists, and
    /// pedestrians, with mock signs shown on screen.
    @Published var roadDetection: Bool {
        didSet { defaults.set(roadDetection, forKey: Keys.roadDetection) }
    }
}
