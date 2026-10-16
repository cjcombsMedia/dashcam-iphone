import AVFoundation
import PhotosUI
import SwiftUI

/// Training / detection test bench: feed the detector a photo or a video
/// frame and see exactly what it read, what it matched, and why something
/// failed — without driving. Frames can be saved as labeled training data
/// for the Core ML detector.
struct TrainingModeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var report: DetectionReport?
    @State private var isAnalyzing = false
    @State private var videoFindings: [(time: Double, summary: String)] = []
    @State private var savedNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhotosPicker(
                        selection: $pickerItem,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Choose photo or video", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if isAnalyzing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Analyzing…")
                        }
                    }

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                if let report {
                                    DetectionBoxesOverlay(report: report)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if let report {
                        resultSection(report)
                    }

                    if !videoFindings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Video scan")
                                .font(.headline)
                            ForEach(Array(videoFindings.enumerated()), id: \.offset) { _, finding in
                                Text("\(Format.duration(finding.time)) — \(finding.summary)")
                                    .font(.caption.monospaced())
                            }
                        }
                    }

                    if let savedNote {
                        Text(savedNote)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding()
            }
            .navigationTitle("Detection Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: pickerItem) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ report: DetectionReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected signs")
                .font(.headline)
            if report.signs.isEmpty {
                Text("none")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.signs.enumerated()), id: \.offset) { _, sign in
                    Text("• \(describe(sign))")
                        .font(.callout)
                }
            }

            Text("Traffic signal lamps")
                .font(.headline)
            HStack(spacing: 12) {
                lampChip("RED", on: report.signalRed, color: .red)
                lampChip("YELLOW", on: report.signalYellow, color: .yellow)
                lampChip("GREEN", on: report.signalGreen, color: .green)
            }

            Text("Symbol signs (colour + shape)")
                .font(.headline)
            HStack(spacing: 12) {
                lampChip("SCHOOL", on: report.schoolBlob, color: Color(red: 0.81, green: 1, blue: 0.11))
                lampChip("HOSPITAL", on: report.hospitalBlob, color: .blue)
                lampChip("BIKE", on: report.bikeBlob, color: .green)
                lampChip("HUMANS: \(report.humanBoxes.count)", on: !report.humanBoxes.isEmpty, color: .cyan)
            }

            Text("OCR text read (\(report.ocrLines.count))")
                .font(.headline)
            if report.ocrLines.isEmpty {
                Text("nothing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(report.ocrLines.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if !report.notes.isEmpty {
                Text("Diagnosis")
                    .font(.headline)
                ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                    Text("• \(note)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if image != nil {
                Button {
                    saveTrainingFrame()
                } label: {
                    Label("Save frame as training data", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func lampChip(_ title: String, on: Bool, color: Color) -> some View {
        Text(title)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(on ? color.opacity(0.35) : Color.gray.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? color : .secondary)
    }

    private func describe(_ sign: RoadSign) -> String {
        switch sign {
        case .speedLimit(let value): return "Speed limit \(value)"
        case .speedHump(let mph): return "Speed hump\(mph.map { " (\($0) mph)" } ?? "")"
        case .hospital: return "Hospital"
        case .bikeLane: return "Bike route"
        case .schoolCrossing(let mph): return "School crossing\(mph.map { " (\($0) mph)" } ?? "")"
        case .cityEntry(let name): return "Entering \(name)"
        case .fireStation(let number): return "Fire station\(number.map { " \($0)" } ?? "")"
        case .stop: return "Stop sign"
        case .yield: return "Yield"
        case .railroad: return "Railroad crossing"
        case .pedestrianCrossing: return "Pedestrian crossing"
        case .doNotEnter: return "Do not enter"
        case .bridgeClearance(let clearance): return "Clearance \(clearance.label)"
        case .exit(let info):
            return "Exit \(info.number ?? "?")"
                + (info.destination.map { " — \($0)" } ?? "")
        case .route(let shield, let number, let direction):
            return "\(direction ?? "") \(shield.label)-\(number)".trimmingCharacters(in: .whitespaces)
        case .services(let kinds):
            return "Services: " + kinds.map(\.label).sorted().joined(separator: ", ")
        case .landmark(let name): return "Landmark: \(name)"
        case .speedReducedAhead: return "Speed reduced ahead"
        case .merge(let kind): return kind.label
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let pickerItem else { return }
        isAnalyzing = true
        report = nil
        videoFindings = []
        savedNote = nil
        defer { isAnalyzing = false }

        if let data = try? await pickerItem.loadTransferable(type: Data.self),
           let loaded = UIImage(data: data) {
            image = loaded
            report = DetectionDiagnostics.analyze(image: loaded)
            return
        }
        if let movie = try? await pickerItem.loadTransferable(type: VideoFile.self) {
            await scanVideo(at: movie.url)
        }
    }

    /// Samples a video every second and reports what fired, so a whole drive
    /// clip can be checked at once.
    private func scanVideo(at url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return }
        let total = CMTimeGetSeconds(duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var findings: [(Double, String)] = []
        var lastImage: UIImage?
        var second = 0.0
        while second < total {
            let time = CMTime(seconds: second, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: time) {
                let frame = UIImage(cgImage: cgImage)
                lastImage = frame
                let frameReport = DetectionDiagnostics.analyze(image: frame)
                var parts: [String] = frameReport.signs.map { describe($0) }
                if frameReport.signalRed { parts.append("signal RED") }
                if frameReport.signalYellow { parts.append("signal YELLOW") }
                if frameReport.signalGreen { parts.append("signal GREEN") }
                if frameReport.schoolBlob { parts.append("school blob") }
                if !frameReport.humanBoxes.isEmpty { parts.append("\(frameReport.humanBoxes.count) human(s)") }
                if !parts.isEmpty {
                    findings.append((second, parts.joined(separator: ", ")))
                }
            }
            second += 1
        }
        image = lastImage
        videoFindings = findings
        if findings.isEmpty {
            videoFindings = [(0, "nothing detected in any sampled frame")]
        }
    }

    /// Writes the frame into Documents/TrainingData for the future Core ML
    /// trainer (it rides the Mac offload).
    private func saveTrainingFrame() {
        guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("TrainingData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "frame-\(formatter.string(from: Date())).jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            savedNote = "Saved \(name) to Documents/TrainingData"
            DiagLog.shared.info("Training: saved \(name)")
        } catch {
            savedNote = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// Boxes drawn over the analyzed image.
private struct DetectionBoxesOverlay: View {
    let report: DetectionReport

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(report.signalRegions.enumerated()), id: \.offset) { _, box in
                rect(box, in: geo.size, color: .yellow)
            }
            ForEach(Array(report.humanBoxes.enumerated()), id: \.offset) { _, box in
                rect(box, in: geo.size, color: .cyan)
            }
        }
    }

    private func rect(_ box: CGRect, in size: CGSize, color: Color) -> some View {
        Rectangle()
            .stroke(color, lineWidth: 2)
            .frame(width: box.width * size.width, height: box.height * size.height)
            .offset(x: box.minX * size.width, y: box.minY * size.height)
    }
}

/// Transferable wrapper so the picker can hand us a video file URL.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("training-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}
