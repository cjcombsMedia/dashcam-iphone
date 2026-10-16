import Foundation
import CoreLocation

/// Satellite fix quality for the speed readout. GPS itself needs no network —
/// the app works fully offline.
enum GPSFixQuality {
    case none
    case poor
    case good

    var label: String {
        switch self {
        case .none: return "No GPS fix"
        case .poor: return "Weak GPS"
        case .good: return "GPS locked"
        }
    }
}

/// Publishes live speed, heading, and position for the overlay/HUD and the
/// 1 Hz telemetry sidecar.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var staleTimer: Timer?
    private var lastFixAt: Date?

    /// How old a fix can be before the satellite indicator degrades to "none".
    private static let staleFixInterval: TimeInterval = 10
    /// Horizontal accuracy (meters) beyond which the fix counts as poor.
    private static let poorAccuracyMeters: Double = 50

    @Published private(set) var speedMPS: Double = -1
    @Published private(set) var headingDegrees: Double = -1
    @Published private(set) var latitude: Double?
    @Published private(set) var longitude: Double?
    @Published private(set) var altitude: Double?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var fixQuality: GPSFixQuality = .none

    /// Offline heading fallback (gyro+magnetometer fusion from MotionService),
    /// used when neither the compass nor GPS course has a valid value.
    var headingFallback: (() -> Double?)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        startStaleTimer()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        staleTimer?.invalidate()
        staleTimer = nil
    }

    /// Asks for Always authorization (needed so a dash-mounted phone keeps
    /// its fix without re-prompting). iOS shows the upgrade prompt at most
    /// once; callers fall back to opening Settings.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// Best available heading: compass → GPS course → fused gyro fallback.
    func effectiveHeading() -> Double {
        if headingDegrees >= 0 { return headingDegrees }
        return headingFallback?() ?? -1
    }

    func currentSample() -> TelemetrySample {
        TelemetrySample(
            timestamp: Date(),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            speedMPS: speedMPS >= 0 ? speedMPS : nil,
            headingDegrees: effectiveHeading() >= 0 ? effectiveHeading() : nil
        )
    }

    private func startStaleTimer() {
        staleTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let last = self.lastFixAt {
                    if Date().timeIntervalSince(last) > Self.staleFixInterval, self.fixQuality != .none {
                        self.fixQuality = .none
                    }
                } else if self.fixQuality != .none {
                    self.fixQuality = .none
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { self.authorizationStatus = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.speedMPS = location.speed
            self.latitude = location.coordinate.latitude
            self.longitude = location.coordinate.longitude
            self.altitude = location.altitude

            let accuracy = location.horizontalAccuracy
            if accuracy < 0 {
                self.fixQuality = .none
            } else {
                self.lastFixAt = Date()
                self.fixQuality = accuracy <= Self.poorAccuracyMeters ? .good : .poor
            }

            // Fall back to GPS course when the compass is unavailable.
            if !CLLocationManager.headingAvailable(), location.course >= 0 {
                self.headingDegrees = location.course
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        DispatchQueue.main.async { self.headingDegrees = degrees }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep last known values; telemetry samples simply omit what we lack.
    }
}
