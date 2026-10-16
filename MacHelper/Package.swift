// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DashCamStudio",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared logic: offload receiver, models, label store, exporters.
        .target(name: "DashCamKit", path: "Sources/DashCamKit"),
        // Headless receiver (no UI) — same protocol as the app.
        .executableTarget(
            name: "dashcam-offload-helper",
            dependencies: ["DashCamKit"],
            path: "Sources/dashcam-offload-helper"
        ),
        // The labeling studio.
        .executableTarget(
            name: "DashCamStudio",
            dependencies: ["DashCamKit"],
            path: "Sources/DashCamStudio"
        ),
        .testTarget(
            name: "DashCamKitTests",
            dependencies: ["DashCamKit"],
            path: "Tests/DashCamKitTests"
        ),
    ]
)
