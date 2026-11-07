// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EchoRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EchoRecorder",
            path: "Sources/EchoRecorder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
