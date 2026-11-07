// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClearCall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClearCall",
            path: "Sources/ClearCall",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
