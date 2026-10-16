import Foundation
import CoreMotion

/// User acceleration (gravity removed), in g.
struct AccelerationSample {
    var time: TimeInterval
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

/// Separates real road events from the mount's own buzz.
///
/// A phone on a suction cup and arm is a spring-mass system: the arm
/// resonates with engine and tyre noise, so the accelerometer sees a
/// continuous 0.2–0.4 g oscillation that has nothing to do with the road.
/// Reporting raw magnitude (worse, a peak-hold of it) pins the readout in
/// the orange all drive and buries the events that matter.
///
/// So this tracks the background level the mount is producing right now and
/// reports everything relative to it:
///
/// - `noiseFloor` — the mount's own contribution. Rises slowly (a rough road
///   is real and should read rough for a while) and falls quickly (once the
///   road smooths out the floor follows down).
/// - `excess` — roughness above that floor. This is what the driver sees.
/// - `smoothed` — low-passed magnitude for braking, which is a sustained
///   push, not a vibration; the low-pass makes buzz average out to nothing.
///
/// A pothole or a collision is a short spike far above the floor, and a
/// spike that brief barely moves a floor with a 20-second attack — so hard
/// hits stay visible no matter how much the mount is humming.
struct VibrationAnalyzer {
    /// How fast the floor climbs toward a sustained new level (seconds).
    static let floorAttack: Double = 20
    /// How fast it falls when things quieten down (seconds).
    static let floorRelease: Double = 3
    /// Envelope release for the displayed number — long enough to read.
    static let envelopeRelease: Double = 0.6
    /// Low-pass for the braking signal.
    static let brakingSmoothing: Double = 0.25
    /// Detection stays off until the floor has had time to settle.
    static let warmUp: Double = 3.0

    private(set) var noiseFloor: Double = 0
    private(set) var envelope: Double = 0
    private(set) var smoothed: Double = 0
    private(set) var elapsed: Double = 0

    /// Roughness above the mount's own buzz, in g. Never negative.
    var excess: Double { max(0, envelope - noiseFloor) }
    /// True once the floor has settled and detection can be trusted.
    var isReady: Bool { elapsed >= Self.warmUp }

    private static func alpha(dt: Double, tau: Double) -> Double {
        guard tau > 0 else { return 1 }
        return 1 - exp(-dt / tau)
    }

    /// Feeds one sample. `dt` is the interval since the previous sample.
    ///
    /// - Returns: the instantaneous excess for this sample, which is what
    ///   impact detection judges.
    @discardableResult
    mutating func process(magnitude: Double, dt: Double) -> Double {
        let step = max(0.001, min(dt, 0.5))   // ignore gaps from a stalled queue
        elapsed += step

        // Peak envelope: jump straight up, ease back down.
        envelope = magnitude > envelope
            ? magnitude
            : envelope + (magnitude - envelope) * Self.alpha(dt: step, tau: Self.envelopeRelease)

        smoothed += (magnitude - smoothed) * Self.alpha(dt: step, tau: Self.brakingSmoothing)

        // Seed quickly on the first samples so the floor doesn't start at
        // zero and read every bump as an impact.
        if elapsed < Self.warmUp {
            noiseFloor += (smoothed - noiseFloor) * Self.alpha(dt: step, tau: 0.5)
        } else {
            let tau = smoothed > noiseFloor ? Self.floorAttack : Self.floorRelease
            noiseFloor += (smoothed - noiseFloor) * Self.alpha(dt: step, tau: tau)
        }

        return max(0, magnitude - noiseFloor)
    }

    /// Braking signal: sustained acceleration with the buzz filtered out.
    var brakingMagnitude: Double { max(0, smoothed - noiseFloor) }
}

/// Pure detection logic, unit-testable with synthetic samples.
///
/// - Impact: any single sample at/above the impact threshold.
/// - Hard braking: magnitude at/above the braking threshold (but below the
///   impact threshold) sustained for `brakingSustain` seconds.
/// - A cooldown suppresses repeat triggers from one event.
struct AutoTagDetector {
    static let cooldown: TimeInterval = 10
    static let brakingSustain: TimeInterval = 0.5

    var sensitivity: AutoTagSensitivity

    private var lastTriggerTime: TimeInterval = -.infinity
    private var brakingStart: TimeInterval?

    init(sensitivity: AutoTagSensitivity) {
        self.sensitivity = sensitivity
    }

    /// Judges one sample.
    ///
    /// - Parameters:
    ///   - impactG: instantaneous acceleration ABOVE the mount's noise floor.
    ///     Using the excess rather than raw magnitude is what stops a
    ///     resonating suction-cup arm from reading as a collision.
    ///   - brakingG: low-passed acceleration above the floor, so a sustained
    ///     push is measured without the buzz riding on top of it.
    mutating func process(
        _ sample: AccelerationSample,
        impactG: Double,
        brakingG: Double
    ) -> TagSource? {
        let inCooldown = sample.time - lastTriggerTime < Self.cooldown

        if impactG >= sensitivity.impactThresholdG {
            brakingStart = nil
            guard !inCooldown else { return nil }
            lastTriggerTime = sample.time
            return .impact
        }

        if brakingG >= sensitivity.brakingThresholdG {
            guard !inCooldown else { return nil }
            if let start = brakingStart {
                if sample.time - start >= Self.brakingSustain {
                    brakingStart = nil
                    lastTriggerTime = sample.time
                    return .hardBraking
                }
            } else {
                brakingStart = sample.time
            }
        } else {
            brakingStart = nil
        }
        return nil
    }
}

/// Continuous device-motion monitor. Provides a gyro+magnetometer fused
/// heading (no network or GPS needed — fully offline) and, while recording,
/// feeds the impact / hard-braking detector.
final class MotionService {
    private let motionManager = CMMotionManager()
    private var detector: AutoTagDetector
    private let queue = OperationQueue()
    private let stateLock = NSLock()
    private var fusedHeading: Double?
    private var vibrationExcess: Double = 0
    private var mountNoiseFloor: Double = 0
    private var detecting = false
    /// Only touched on the motion queue.
    private var analyzer = VibrationAnalyzer()
    private var lastSampleTime: TimeInterval?

    /// Called on the main queue when an impact or hard-braking event fires.
    var onAutoTag: ((TagSource) -> Void)?

    init(sensitivity: AutoTagSensitivity) {
        detector = AutoTagDetector(sensitivity: sensitivity)
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.cjcombs.dashcam.motion"
    }

    /// Latest fused heading in degrees (0–360, magnetic north), or nil when
    /// device motion is unavailable. Thread-safe.
    var currentHeading: Double? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fusedHeading
    }

    /// Ride roughness in g, measured ABOVE whatever the mount is producing
    /// on its own — so a resonating suction-cup arm reads near zero and a
    /// real pothole still reads large. Thread-safe.
    var currentVibrationG: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return vibrationExcess
    }

    /// The mount's own contribution right now, for diagnostics.
    var currentMountNoiseFloor: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mountNoiseFloor
    }

    func updateSensitivity(_ sensitivity: AutoTagSensitivity) {
        queue.addOperation { [weak self] in
            self?.detector = AutoTagDetector(sensitivity: sensitivity)
        }
    }

    /// Starts continuous device-motion updates (heading fusion runs for the
    /// whole session; the phone is on constant power per the operating model).
    func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0

        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical
            : .xArbitraryZVertical
        let headingAvailable = frame == .xMagneticNorthZVertical

        motionManager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let sample = AccelerationSample(
                time: motion.timestamp,
                x: motion.userAcceleration.x,
                y: motion.userAcceleration.y,
                z: motion.userAcceleration.z
            )

            let dt = self.lastSampleTime.map { motion.timestamp - $0 } ?? (1.0 / 30.0)
            self.lastSampleTime = motion.timestamp
            let impactG = self.analyzer.process(magnitude: sample.magnitude, dt: dt)
            let brakingG = self.analyzer.brakingMagnitude
            let ready = self.analyzer.isReady

            self.stateLock.lock()
            if headingAvailable, motion.heading >= 0 {
                self.fusedHeading = motion.heading
            }
            // What the driver sees: roughness above the mount's own buzz.
            self.vibrationExcess = self.analyzer.excess
            self.mountNoiseFloor = self.analyzer.noiseFloor
            let isDetecting = self.detecting
            self.stateLock.unlock()

            // Don't judge anything until the noise floor has settled, or the
            // first seconds after launch fire a false impact every time.
            guard isDetecting, ready else { return }
            if let source = self.detector.process(sample, impactG: impactG, brakingG: brakingG) {
                DiagLog.shared.info(String(
                    format: "Motion: %@ — %.2fg over a %.2fg mount floor",
                    String(describing: source), impactG, self.analyzer.noiseFloor
                ))
                DispatchQueue.main.async { self.onAutoTag?(source) }
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
    }

    /// Enables impact / hard-braking detection (recording only).
    func setDetecting(_ on: Bool) {
        stateLock.lock()
        detecting = on
        stateLock.unlock()
    }

    /// Debug hook: fires the auto-tag path as if a real impact occurred.
    func simulateImpact() {
        DispatchQueue.main.async { [weak self] in
            self?.onAutoTag?(.impact)
        }
    }
}
