import AppKit
import SwiftUI

@main
struct DashCamStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DashCam Studio") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_240, minHeight: 720)
                .onAppear {
                    model.startReceiver()
                    // Quitting must never drop labelling work.
                    AppDelegate.saveOnQuit = { [weak model] in model?.saveLabels() }
                }
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save clip labels") { model.saveLabels() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh clips") { model.refreshClips() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Export road memory for iPhone") { model.exportRoadMemory() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export training dataset") { model.exportTrainingDataset() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// Running a SwiftUI app from a SwiftPM executable needs the activation
/// policy set explicitly, otherwise it launches without a Dock icon or focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so quitting always flushes the open clip's labels.
    @MainActor static var saveOnQuit: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Save before the process goes away. Every edit is already journalled,
    /// so this just writes the tidy labels file too.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.saveOnQuit?()
        return .terminateNow
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Self.saveOnQuit?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
