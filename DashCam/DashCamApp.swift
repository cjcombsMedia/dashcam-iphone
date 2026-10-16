import SwiftData
import SwiftUI
import UIKit

/// Owns the interface-orientation lock. The app is landscape-only; while
/// recording, the mask narrows further to the exact landscape orientation
/// recording started in.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .landscape

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    static func apply(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }

    /// Lets in-flight background offload uploads finish after a relaunch.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        OffloadService.backgroundCompletionHandler = completionHandler
    }
}

@main
struct DashCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: RecordingViewModel
    @StateObject private var library: LibraryViewModel
    @StateObject private var offload: OffloadService
    @StateObject private var roadScene: RoadScene
    @StateObject private var roadMemory: RoadMemory

    init() {
        DiagLog.shared.installCrashReporting()

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: ClipSegment.self, TagMark.self, SessionLog.self, RoadFeature.self,
                ForgottenFeature.self
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container

        let settings = AppSettings()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let storage = StorageManager(rootURL: documents)
        let tagStore = TagStore(storage: storage)
        let capture = CaptureService()
        let viewModel = RecordingViewModel(
            settings: settings,
            capture: capture,
            location: LocationService(),
            motion: MotionService(sensitivity: settings.sensitivity),
            storage: storage,
            tagStore: tagStore,
            modelContext: container.mainContext
        )
        let offload = OffloadService(
            settings: settings,
            storage: storage,
            tagStore: tagStore,
            modelContext: container.mainContext
        )
        offload.isRecordingProvider = { [weak capture] in capture?.isRecording ?? false }

        // Road-scene detection: signs, signals, cyclists, pedestrians.
        let roadScene = RoadScene()
        let roadAnalyzer = RoadSceneAnalyzer(scene: roadScene)
        roadScene.analyzer = roadAnalyzer
        roadAnalyzer.isEnabled = settings.roadDetection
        capture.roadFrameSink = { [weak roadAnalyzer] pixelBuffer, time in
            roadAnalyzer?.ingest(pixelBuffer, at: time)
        }
        capture.roadLampSink = { [weak roadAnalyzer] pixelBuffer, time in
            roadAnalyzer?.ingestLamp(pixelBuffer, at: time)
        }
        capture.emergencyExclusionProvider = { [weak roadAnalyzer] in
            roadAnalyzer?.currentSignalRegions() ?? []
        }
        viewModel.roadScene = roadScene

        // Geo memory: learn confirmed detections, recall them on later passes.
        let roadMemory = RoadMemory(modelContext: container.mainContext)
        roadScene.memory = roadMemory
        let locationService = viewModel.location
        let motionService = viewModel.motion
        roadScene.positionProvider = { [weak locationService, weak motionService] in
            guard let locationService,
                  let lat = locationService.latitude,
                  let lon = locationService.longitude else { return nil }
            let heading = locationService.headingDegrees >= 0
                ? locationService.headingDegrees
                : (motionService?.currentHeading ?? -1)
            return (lat, lon, heading)
        }

        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: viewModel)
        _library = StateObject(wrappedValue: LibraryViewModel(tagStore: tagStore, storage: storage, settings: settings))
        _offload = StateObject(wrappedValue: offload)
        _roadScene = StateObject(wrappedValue: roadScene)
        offload.roadMemory = roadMemory
        _roadMemory = StateObject(wrappedValue: roadMemory)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordingScreen()
                .environmentObject(settings)
                .environmentObject(viewModel)
                .environmentObject(library)
                .environmentObject(offload)
                .environmentObject(roadScene)
                .environmentObject(roadMemory)
                .modelContainer(container)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase) {
            // Leaving the app fully shuts services down; returning starts a
            // fresh session with the startup checklist.
            switch scenePhase {
            case .background:
                viewModel.appEnteredBackground()
            case .active:
                viewModel.appBecameActive()
            default:
                break
            }
        }
    }
}
