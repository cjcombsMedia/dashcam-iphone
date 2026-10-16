// Headless DashCam offload receiver.
//
// Same protocol as DashCam Studio — use this when you just want footage to
// land on the Mac without the labelling UI (e.g. run at login).
//
//   swift run --package-path MacHelper dashcam-offload-helper
import DashCamKit
import Foundation

let workspace = Workspace()
let receiver = OffloadReceiver(workspace: workspace)

receiver.onEvent = { event in
    let stamp = ISO8601DateFormatter().string(from: event.date)
    print("[\(stamp)] \(event.message)")
}

do {
    try receiver.start()
} catch {
    print("Failed to start: \(error.localizedDescription)")
    exit(1)
}

dispatchMain()
