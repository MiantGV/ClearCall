// swift-tools-version:5.10
import PackageDescription

// WebRTC's audio processing library is built by scripts/build-webrtc.sh into vendor/webrtc.
// Its include and link flags are passed by scripts/build-app.sh (from pkg-config).
let package = Package(
    name: "ClearCall",
    platforms: [.macOS("14.4")],
    targets: [
        .target(
            name: "CEchoCancel",
            path: "Sources/CEchoCancel"
        ),
        .executableTarget(
            name: "ClearCall",
            dependencies: ["CEchoCancel"],
            path: "Sources/ClearCall",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedLibrary("c++"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
