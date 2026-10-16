import AVFoundation
import DashCamKit
import SwiftUI

/// Hosts the AVPlayer so the clip can actually play, with labels drawn on
/// top. Boxes are stored relative to the VIDEO, not the view, so they stay
/// correct despite letterboxing — that matters because these coordinates
/// become training data.
struct VideoBoxCanvas: View {
    let player: AVPlayer
    /// Video pixel size, for the letterbox maths.
    let videoSize: CGSize
    let labels: [FrameLabel]
    let classes: [LabelClass]
    @Binding var selectedLabelID: UUID?
    let activeClass: LabelClass?

    var onCreate: (CGRect) -> Void
    var onUpdate: (UUID, CGRect) -> Void
    var onChangeClass: (UUID, LabelClass) -> Void
    var onDelete: (UUID) -> Void
    /// Clicking empty video puts everything down.
    var onDeselect: (() -> Void)?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var moveOrigin: CGRect?
    @State private var resizeOrigin: CGRect?

    var body: some View {
        GeometryReader { geo in
            let content = contentRect(in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.black
                // The AVPlayer NSView must not eat mouse events, or clicks
                // never reach the boxes drawn above it.
                PlayerLayerView(player: player)
                    .allowsHitTesting(false)

                // Drawing new boxes happens on this layer, which sits BELOW
                // the existing boxes. Putting this gesture on the container
                // instead swallowed every click and right-click meant for a
                // box — that was the "can't edit a tag" bug.
                Color.clear
                    .contentShape(Rectangle())
                    // A click on empty video deselects. The drag gesture
                    // below needs 4pt of movement before it fires, so a
                    // plain click here reached nothing at all.
                    .onTapGesture { onDeselect?() }
                    .gesture(createGesture(content: content))

                ForEach(labels) { label in
                    let rect = pixelRect(label, in: content)
                    let colour = color(for: label.className)
                    let isSelected = selectedLabelID == label.id

                    ZStack(alignment: .topLeading) {
                        // A real filled shape so the box interior reliably
                        // receives mouse events — a stroked outline alone is
                        // hollow, which is why dragging didn't take.
                        Rectangle()
                            .fill(Color.white.opacity(isSelected ? 0.06 : 0.001))
                            .frame(width: rect.width, height: rect.height)
                        Rectangle()
                            .stroke(colour, lineWidth: isSelected ? 3 : 2)
                            .frame(width: rect.width, height: rect.height)
                        Text(labelText(label))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(colour)
                            .foregroundStyle(.black)
                            .offset(y: -14)
                    }
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    // ONE gesture handles both select and move. Separate tap
                    // and drag gestures on the same view fight each other,
                    // and the drag was losing.
                    .gesture(selectOrMoveGesture(label: label, rect: rect, content: content))
                    .contextMenu {
                        Text(labelText(label))
                        Divider()
                        Menu("Change class") {
                            ForEach(groupedClasses, id: \.key) { group, items in
                                Section(group) {
                                    ForEach(items) { item in
                                        Button(item.display) {
                                            onChangeClass(label.id, item)
                                            selectedLabelID = label.id
                                        }
                                    }
                                }
                            }
                        }
                        Button("Edit in panel") { selectedLabelID = label.id }
                        Divider()
                        Button("Delete box", role: .destructive) { onDelete(label.id) }
                    }

                    if isSelected {
                        Rectangle()
                            .fill(colour)
                            .frame(width: 12, height: 12)
                            .offset(x: rect.maxX - 6, y: rect.maxY - 6)
                            .gesture(resizeGesture(label: label, rect: rect, content: content))
                    }
                }

                if let start = dragStart, let current = dragCurrent {
                    let rect = CGRect(
                        x: min(start.x, current.x), y: min(start.y, current.y),
                        width: abs(current.x - start.x), height: abs(current.y - start.y)
                    )
                    Rectangle()
                        .stroke(activeColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    // MARK: - Letterbox geometry

    /// Where the video actually sits inside the view (AVLayerVideoGravity
    /// .resizeAspect letterboxes it).
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

    private func pixelRect(_ label: FrameLabel, in content: CGRect) -> CGRect {
        CGRect(
            x: content.minX + label.x * content.width,
            y: content.minY + label.y * content.height,
            width: label.width * content.width,
            height: label.height * content.height
        )
    }

    private func normalized(_ rect: CGRect, in content: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        return CGRect(
            x: max(0, min(1, (rect.minX - content.minX) / content.width)),
            y: max(0, min(1, (rect.minY - content.minY) / content.height)),
            width: max(0.002, min(1, rect.width / content.width)),
            height: max(0.002, min(1, rect.height / content.height))
        )
    }

    // MARK: - Gestures

    private func createGesture(content: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard moveOrigin == nil, resizeOrigin == nil else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer { dragStart = nil; dragCurrent = nil }
                guard moveOrigin == nil, resizeOrigin == nil,
                      let start = dragStart, activeClass != nil else { return }
                let rect = CGRect(
                    x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                    width: abs(value.location.x - start.x), height: abs(value.location.y - start.y)
                )
                guard rect.width > 6, rect.height > 6 else { return }
                onCreate(normalized(rect, in: content))
            }
    }

    /// Press selects the box; dragging past a couple of points moves it.
    /// Handling both in a single gesture avoids the tap-vs-drag arbitration
    /// that was swallowing the move.
    private func selectOrMoveGesture(label: FrameLabel, rect: CGRect, content: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moveOrigin == nil {
                    moveOrigin = rect
                    selectedLabelID = label.id
                }
                guard let origin = moveOrigin else { return }
                // Ignore the jitter of a plain click.
                guard abs(value.translation.width) > 2 || abs(value.translation.height) > 2 else { return }
                let moved = CGRect(
                    x: origin.minX + value.translation.width,
                    y: origin.minY + value.translation.height,
                    width: origin.width, height: origin.height
                )
                onUpdate(label.id, normalized(moved, in: content))
            }
            .onEnded { _ in moveOrigin = nil }
    }

    private func resizeGesture(label: FrameLabel, rect: CGRect, content: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeOrigin == nil { resizeOrigin = rect }
                guard let origin = resizeOrigin else { return }
                let resized = CGRect(
                    x: origin.minX, y: origin.minY,
                    width: max(8, origin.width + value.translation.width),
                    height: max(8, origin.height + value.translation.height)
                )
                onUpdate(label.id, normalized(resized, in: content))
            }
            .onEnded { _ in resizeOrigin = nil }
    }

    // MARK: - Appearance

    private var activeColor: Color {
        activeClass.map { Color(hex: $0.color) } ?? .yellow
    }

    private func color(for className: String) -> Color {
        classes.first { $0.name == className }.map { Color(hex: $0.color) } ?? .yellow
    }

    private func labelText(_ label: FrameLabel) -> String {
        let display = classes.first { $0.name == label.className }?.display ?? label.className
        return label.value.map { "\(display) \($0)" } ?? display
    }

    private var groupedClasses: [(key: String, value: [LabelClass])] {
        Dictionary(grouping: classes, by: \.group)
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }
}

/// AVPlayerLayer host.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}

extension Color {
    init(hex: String) {
        var value = UInt64()
        var cleaned = hex
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
