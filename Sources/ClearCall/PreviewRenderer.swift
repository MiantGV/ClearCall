import AppKit
import SwiftUI

/// `ClearCall --render-previews <folder>` writes PNGs of the window (used by the build to check the design).
@MainActor
enum PreviewRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count else { return false }
        let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let controller = AppController.shared
        let samples = [
            RecordingItem(url: URL(fileURLWithPath: "/tmp/Recording 2026-11-08 at 16.53.07.m4a"), date: Date().addingTimeInterval(-3600), duration: 86),
            RecordingItem(url: URL(fileURLWithPath: "/tmp/Recording 2026-11-08 at 16.22.21.m4a"), date: Date().addingTimeInterval(-5400), duration: 312),
            RecordingItem(url: URL(fileURLWithPath: "/tmp/Recording 2026-11-07 at 10.02.44.m4a"), date: Date().addingTimeInterval(-90000), duration: 2710),
        ]

        let states: [(String, Bool, String?)] = [("idle", false, nil), ("call", false, "WhatsApp"), ("recording", true, "WhatsApp")]
        for (name, recording, call) in states {
            controller.applyPreview(recording: recording, call: call, recent: samples)
            for scheme in [ColorScheme.light, .dark] {
                let view = MainView(openSettings: {})
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                save(view, to: folder.appendingPathComponent("window-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        save(SettingsView().background(Color(white: 0.95)), to: folder.appendingPathComponent("settings.png"))
        return true
    }

    private static func save<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("could not render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("rendered \(url.lastPathComponent)")
    }
}
