import SwiftUI

/// Blocking modal shown once per launch before recording can start.
struct StartupAcknowledgmentView: View {
    var acknowledge: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Before you record")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 18) {
                    checklistRow(
                        icon: "bolt.fill",
                        text: "Phone is connected to constant power"
                    )
                    checklistRow(
                        icon: "iphone",
                        text: "Screen stays unlocked and the app stays in the foreground"
                    )
                    checklistRow(
                        icon: "car.fill",
                        text: "Phone is mounted securely with a clear windshield view"
                    )
                }
                .padding(.horizontal, 12)

                Button(action: acknowledge) {
                    Text("OK, I understand")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 420)
                        .padding(.vertical, 14)
                        .background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .frame(maxWidth: 560)
        }
    }

    private func checklistRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.yellow)
                .frame(width: 30)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
