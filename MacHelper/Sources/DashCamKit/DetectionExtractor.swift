import Foundation

/// Rebuilds the list of notifications the phone showed during a drive from
/// its telemetry sidecar, collapsing the 2 Hz sampling into one entry per
/// appearance so a sign shown for 25 seconds is reviewed once, not 50 times.
public enum DetectionExtractor {

    public static func detections(from sidecar: TelemetrySidecar) -> [PhoneDetection] {
        var found: [PhoneDetection] = []

        // --- Signs and banners, from the on-screen snapshots.
        var lastSpeedLimit: Int?
        var humpRunning = false
        var schoolRunning = false
        var hospitalRunning = false
        var bikeRunning = false
        var lastCity: String?
        var lastFireStation: String?
        var cyclistRunning = false

        for snapshot in sidecar.overlaySnapshots ?? [] {
            let time = snapshot.offset

            if let limit = snapshot.speedLimit, limit != lastSpeedLimit {
                found.append(PhoneDetection(
                    id: "speed-\(limit)-\(Int(time))", time: time,
                    className: "speed_limit", display: "Speed limit",
                    value: String(limit)
                ))
            }
            lastSpeedLimit = snapshot.speedLimit

            let hump = snapshot.humpShowing ?? false
            if hump, !humpRunning {
                found.append(PhoneDetection(
                    id: "hump-\(Int(time))", time: time,
                    className: "hump_sign", display: "Speed hump",
                    value: snapshot.humpSpeed.map(String.init)
                ))
            }
            humpRunning = hump

            let school = snapshot.schoolShowing ?? false
            if school, !schoolRunning {
                found.append(PhoneDetection(
                    id: "school-\(Int(time))", time: time,
                    className: "school_sign", display: "School zone",
                    value: snapshot.schoolSpeed.map(String.init)
                ))
            }
            schoolRunning = school

            let hospital = snapshot.hospitalShowing ?? false
            if hospital, !hospitalRunning {
                found.append(PhoneDetection(
                    id: "hospital-\(Int(time))", time: time,
                    className: "hospital_sign", display: "Hospital"
                ))
            }
            hospitalRunning = hospital

            let bike = snapshot.bikeShowing ?? false
            if bike, !bikeRunning {
                found.append(PhoneDetection(
                    id: "bike-\(Int(time))", time: time,
                    className: "bike_route_sign", display: "Bike route"
                ))
            }
            bikeRunning = bike

            if let city = snapshot.cityName, city != lastCity {
                found.append(PhoneDetection(
                    id: "city-\(city)-\(Int(time))", time: time,
                    className: "city_limit_sign", display: "City limits", value: city
                ))
            }
            lastCity = snapshot.cityName

            if let station = snapshot.fireStation, station != lastFireStation {
                let number = station.components(separatedBy: " ").last.flatMap { Int($0) }
                found.append(PhoneDetection(
                    id: "fire-\(station)-\(Int(time))", time: time,
                    className: "fire_station_sign", display: "Fire station",
                    value: number.map(String.init)
                ))
            }
            lastFireStation = snapshot.fireStation

            let cyclist = snapshot.cyclist != nil
            if cyclist, !cyclistRunning {
                found.append(PhoneDetection(
                    id: "person-\(Int(time))", time: time,
                    className: "pedestrian", display: "Person / cyclist warning",
                    value: snapshot.cyclist
                ))
            }
            cyclistRunning = cyclist

            // Pedestrian boxes carry real geometry — good training data.
            if let boxes = snapshot.pedestrians {
                for (index, box) in boxes.enumerated() where box.count == 4 {
                    found.append(PhoneDetection(
                        id: "ped-\(Int(time * 2))-\(index)", time: time,
                        className: "pedestrian", display: "Pedestrian", box: box
                    ))
                }
            }
        }

        // --- Traffic signals: each state change is one detection.
        for event in sidecar.signalEvents ?? [] where event.state != "none" {
            let className: String
            switch event.state {
            case "red": className = "signal_red"
            case "yellow": className = "signal_yellow"
            case "green": className = "signal_green"
            case "flashingYellow": className = "signal_arrow"
            default: continue
            }
            found.append(PhoneDetection(
                id: "signal-\(event.state)-\(Int(event.offset))", time: event.offset,
                className: className, display: "Signal — \(event.state)"
            ))
        }

        // --- Emergency lights, collapsed into runs.
        var lastEmergency: Double = -100
        for event in (sidecar.emergencyEvents ?? []).sorted(by: { $0.offset < $1.offset }) {
            guard event.offset - lastEmergency > 5 else { continue }
            lastEmergency = event.offset
            found.append(PhoneDetection(
                id: "emergency-\(Int(event.offset))", time: event.offset,
                className: "emergency_lights", display: "Emergency lights",
                box: [event.x, event.y, event.width, event.height]
            ))
        }

        // De-duplicate by id, keep chronological.
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.time < $1.time }
    }
}
