import DashCamKit
import SwiftUI

/// Redraws exactly what the phone showed on screen at this moment in the
/// drive — the same signs, signal mock, warning arrows, and telemetry box —
/// reconstructed from the clip's recorded overlay snapshots.
///
/// Purely visual: it never takes mouse events, so labelling still works
/// underneath it.
struct LiveOverlayView: View {
    let snapshot: OverlaySnapshot?
    let sample: TelemetrySample?
    let emergencyBox: [Double]?
    let videoSize: CGSize
    let timestamp: Date?

    var body: some View {
        GeometryReader { geo in
            let content = contentRect(in: geo.size)

            ZStack(alignment: .topLeading) {
                // Boxes the phone drew.
                if let box = emergencyBox, box.count == 4 {
                    detectionBox(box, in: content, colour: .green, title: "EMERGENCY LIGHTS")
                }
                if let boxes = snapshot?.pedestrians {
                    ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                        if box.count == 4 {
                            detectionBox(box, in: content, colour: .cyan, title: nil)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let station = snapshot?.fireStation {
                        fireStationBar(station)
                    }
                    if let city = snapshot?.cityName {
                        banner("Welcome to \(city)", colour: Color(red: 0, green: 0.45, blue: 0.23))
                    }
                    signRow
                    Spacer()
                    telemetryBox
                }
                .padding(10)
                .frame(width: content.width, height: content.height, alignment: .topLeading)
                .offset(x: content.minX, y: content.minY)

                // Cyclist / person arrow, on the side it was shown.
                if let side = snapshot?.cyclist {
                    VStack(spacing: 2) {
                        Image(systemName: side == "right" ? "arrowshape.right.fill" : "arrowshape.left.fill")
                            .font(.system(size: 34, weight: .black))
                        Text("PERSON")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(.green)
                    .padding(8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    .frame(
                        width: content.width, height: content.height,
                        alignment: side == "right" ? .trailing : .leading
                    )
                    .offset(x: content.minX, y: content.minY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var signRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if let limit = snapshot?.speedLimit {
                speedSign(limit)
            }
            if snapshot?.humpShowing == true {
                chip(["BUMP", (snapshot?.humpSpeed).map { "\($0) MPH" }].compactMap { $0 },
                     background: .yellow, text: .black)
            }
            if snapshot?.schoolShowing == true {
                chip(["SCHOOL", (snapshot?.schoolSpeed).map { "\($0) MPH" }].compactMap { $0 },
                     background: Color(red: 0.81, green: 1, blue: 0.11), text: .black)
            }
            if snapshot?.hospitalShowing == true {
                chip(["H"], background: Color(red: 0, green: 0.28, blue: 0.73), text: .white)
            }
            if snapshot?.bikeShowing == true {
                chip(["BIKE", "ROUTE"], background: Color(red: 0, green: 0.45, blue: 0.23), text: .white)
            }
            if let signal = snapshot?.signal, signal != "none" {
                signalMock(signal)
            }
            Spacer(minLength: 0)
        }
    }

    private func speedSign(_ limit: Int) -> some View {
        VStack(spacing: 0) {
            Text("SPEED").font(.system(size: 8, weight: .bold))
            Text("LIMIT").font(.system(size: 8, weight: .bold))
            Text("\(limit)").font(.system(size: 22, weight: .heavy)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black, lineWidth: 2).padding(1.5))
    }

    private func chip(_ lines: [String], background: Color, text: Color) -> some View {
        VStack(spacing: 1) {
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 10, weight: .heavy))
            }
        }
        .foregroundStyle(text)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(text.opacity(0.9), lineWidth: 1.5).padding(1.5))
    }

    private func signalMock(_ state: String) -> some View {
        VStack(spacing: 4) {
            lamp(.red, lit: state == "red")
            lamp(.yellow, lit: state == "yellow" || state == "flashingYellow")
            lamp(.green, lit: state == "green")
        }
        .padding(5)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lamp(_ colour: Color, lit: Bool) -> some View {
        Circle()
            .fill(lit ? colour : colour.opacity(0.15))
            .frame(width: 12, height: 12)
    }

    private func fireStationBar(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
            Text(label).font(.system(size: 12, weight: .heavy))
            Text("— WATCH FOR EMERGENCY VEHICLES").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.78, green: 0.05, blue: 0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func banner(_ text: String, colour: Color) -> some View {
        Label(text, systemImage: "signpost.right.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colour.opacity(0.9), in: Capsule())
    }

    /// The grey telemetry box from the live screen.
    private var telemetryBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(mph)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("mph").font(.system(size: 13, weight: .bold)).opacity(0.8)
            }
            Text(headingText).font(.system(size: 15, weight: .bold)).monospacedDigit()
            Text(coordinateText).font(.system(size: 10, design: .monospaced)).opacity(0.85)
            if let timestamp {
                Text(timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 2)
        .padding(8)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detectionBox(_ box: [Double], in content: CGRect, colour: Color, title: String?) -> some View {
        let rect = CGRect(
            x: content.minX + box[0] * content.width,
            y: content.minY + box[1] * content.height,
            width: box[2] * content.width,
            height: box[3] * content.height
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(colour, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
            if let title {
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(colour, in: Capsule())
                    .offset(y: -14)
            }
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    // MARK: - Values

    private var mph: Int {
        guard let speed = sample?.speedMPS, speed >= 0 else { return 0 }
        return Int((speed * 2.23694).rounded())
    }

    private var headingText: String {
        guard let heading = sample?.headingDegrees, heading >= 0 else { return "--" }
        let cardinals = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                         "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((heading / 22.5).rounded()) % 16
        return "\(cardinals[index]) \(Int(heading.rounded()))°"
    }

    private var coordinateText: String {
        guard let latitude = sample?.latitude, let longitude = sample?.longitude else { return "--" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    private func contentRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = size.width / size.height
        var drawn = size
        if videoAspect > viewAspect {
            drawn.height = size.width / videoAspect
        } else {
            drawn.width = size.height * videoAspect
        }
        return CGRect(
            x: (size.width - drawn.width) / 2,
            y: (size.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )
    }
}
