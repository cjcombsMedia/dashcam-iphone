import SwiftUI

/// Big red recording indicator, pulsing on a steady ~1 second cycle. Visible
/// in both full-preview and HUD modes.
struct PulsingRecordIndicator: View {
    var night: Bool
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 26, height: 26)
                .scaleEffect(pulsing ? 0.75 : 1.0)
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulsing)
            Text("REC")
                .font(.system(.headline, design: .monospaced).bold())
                .foregroundStyle(night ? Color.orange : Color.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .onAppear { pulsing = true }
        .accessibilityLabel("Recording")
    }
}

/// Large tag button, available in both full and HUD modes.
struct TagButton: View {
    var night: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("TAG", systemImage: "bookmark.fill")
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
                .background(night ? Color.orange.opacity(0.75) : Color.red.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tag this moment")
    }
}

/// HD / 4K selector. Always visible on the main recording screen; disabled
/// and greyed while recording. Changes apply to the next session.
struct ResolutionSelector: View {
    @Binding var resolution: VideoResolution
    var locked: Bool

    var body: some View {
        Picker("Resolution", selection: $resolution) {
            ForEach(VideoResolution.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 112)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }
}

/// Start/stop control.
struct RecordButton: View {
    var isRecording: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 31)
                    .fill(Color.red)
                    .frame(
                        width: isRecording ? 34 : 62,
                        height: isRecording ? 34 : 62
                    )
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Persistent warning when SAVED growth squeezes loop capacity below ~30 min.
struct StorageWarningBanner: View {
    var body: some View {
        Label("Loop space low — export or clean up Saved clips", systemImage: "externaldrive.badge.exclamationmark")
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.red.opacity(0.85), in: Capsule())
    }
}

/// Brief visual confirmation after tagging.
struct TagFlashOverlay: View {
    var body: some View {
        Label("Tagged — moved to Saved", systemImage: "checkmark.circle.fill")
            .font(.title3.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.green.opacity(0.85), in: Capsule())
            .transition(.scale.combined(with: .opacity))
    }
}
