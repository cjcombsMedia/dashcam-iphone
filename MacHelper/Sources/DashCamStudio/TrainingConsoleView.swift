import DashCamKit
import SwiftUI

/// The whole training loop in one window: what you corrected, what is queued
/// for the phone, what the phone did with it, and every message between the
/// two machines.
///
/// The point is that none of it has to be taken on trust. Each number traces
/// to a file on disk and each exchange is timestamped, so the loop can be
/// demonstrated to someone watching over your shoulder.
struct TrainingConsoleView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pipeline
                    corrections
                    phoneStatus
                    conversation
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { model.refreshTraining() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Training")
                    .font(.title2.bold())
                Text("Every correction, every message, every acceptance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshTraining() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    // MARK: - Pipeline

    /// The four stages, each with a live number, so it's obvious where the
    /// work currently sits.
    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Pipeline", "The loop, left to right")
            HStack(spacing: 10) {
                stage("1. Phone detects", "\(detectionsSeen)",
                      "detections recorded", "eye")
                arrow
                stage("2. You review", "\(model.training.totalReviewed)",
                      "corrections made", "hand.point.up.left")
                arrow
                stage("3. Sent to phone", "\(model.lastExportFeatureCount)",
                      "features exported", "arrow.up.forward")
                arrow
                stage("4. Phone accepts",
                      model.phoneReport.map { "\($0.imported)" } ?? "—",
                      "imported last sync", "checkmark.seal")
            }

            HStack(spacing: 10) {
                Button {
                    model.exportRoadMemory()
                } label: {
                    Label("Send corrections to phone", systemImage: "iphone.and.arrow.right.inward")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)

                Text(model.training.totalReviewed == 0
                     ? "Review some detections first — there is nothing to send yet."
                     : "Exports \(model.training.totalConfirmed + model.training.totalCorrected) confirmed/corrected place(s). The phone picks them up on its next connect or when you tap Import on the phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// Total detections the phone produced that you've seen in the console.
    private var detectionsSeen: Int {
        model.training.totalReviewed + model.unreviewedCount
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
    }

    private func stage(_ title: String, _ value: String, _ caption: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption2.bold())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Corrections

    private var corrections: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What you taught it",
                         "\(model.training.clipsReviewed) clip(s) reviewed · \(model.training.boxesDrawn) box(es) drawn")

            if model.training.byClass.isEmpty {
                emptyNote("No corrections yet. Open a clip and use the Detections panel.")
            } else {
                HStack {
                    Text("Detection accuracy so far")
                        .font(.caption.bold())
                    Spacer()
                    Text(percent(model.training.overallAccuracy))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(accuracyColor(model.training.overallAccuracy))
                }
                Text("\(model.training.totalConfirmed) right · \(model.training.totalCorrected) corrected · \(model.training.totalRejected) false positives")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Class").font(.caption.bold())
                        Text("Right").font(.caption.bold())
                        Text("Fixed").font(.caption.bold())
                        Text("Wrong").font(.caption.bold())
                        Text("Accuracy").font(.caption.bold())
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(model.training.byClass) { tally in
                        GridRow {
                            Text(tally.className).font(.caption)
                            Text("\(tally.confirmed)").font(.caption.monospacedDigit())
                            Text("\(tally.corrected)").font(.caption.monospacedDigit())
                            Text("\(tally.rejected)").font(.caption.monospacedDigit())
                            Text(percent(tally.accuracy))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(accuracyColor(tally.accuracy))
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Phone

    private var phoneStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What the phone did", "Reported by the phone itself, not assumed")

            if let report = model.phoneReport {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Device").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.deviceName) · v\(report.appVersion)").font(.caption)
                    }
                    GridRow {
                        Text("Last sync").font(.caption).foregroundStyle(.secondary)
                        Text(report.at.formatted(date: .abbreviated, time: .standard)).font(.caption)
                    }
                    GridRow {
                        Text("Imported").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.imported) correction(s) accepted")
                            .font(.caption).foregroundStyle(report.imported > 0 ? .green : .secondary)
                    }
                    GridRow {
                        Text("Already had").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.skippedAlreadyKnown)").font(.caption)
                    }
                    GridRow {
                        Text("Refused").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.refusedForgotten) previously removed by you")
                            .font(.caption)
                            .foregroundStyle(report.refusedForgotten > 0 ? .orange : .secondary)
                    }
                    GridRow {
                        Text("Unsupported").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.unsupported)")
                            .font(.caption)
                            .foregroundStyle(report.unsupported > 0 ? .red : .secondary)
                    }
                    GridRow {
                        Text("Phone now holds").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.featuresHeld) remembered place(s), \(report.tombstones) removal(s)")
                            .font(.caption.bold())
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                emptyNote("The phone hasn't reported in yet. Send corrections, then tap Import road memory on the phone — its reply appears here.")
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Every message", "\(model.syncEvents.count) exchange(s), newest first")

            if model.syncEvents.isEmpty {
                emptyNote("Nothing yet. Start the receiver and connect the phone.")
            } else {
                VStack(spacing: 0) {
                    ForEach(model.syncEvents.reversed()) { event in
                        eventRow(event)
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func eventRow(_ event: SyncEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: event))
                .foregroundStyle(color(for: event.outcome))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.action).font(.caption.bold())
                    Spacer()
                    Text(event.at.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(event.summary).font(.caption)
                if !event.detail.isEmpty {
                    Text(event.detail.sorted { $0.key < $1.key }
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: "   "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
    }

    private func icon(for event: SyncEvent) -> String {
        switch event.direction {
        case .phoneToMac: return "arrow.up.circle.fill"
        case .macToPhone: return "arrow.down.circle.fill"
        case .local: return "desktopcomputer"
        }
    }

    private func color(for outcome: SyncEvent.Outcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .rejected: return .orange
        case .failed: return .red
        case .info: return .secondary
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func accuracyColor(_ value: Double) -> Color {
        value >= 0.8 ? .green : (value >= 0.5 ? .orange : .red)
    }
}
