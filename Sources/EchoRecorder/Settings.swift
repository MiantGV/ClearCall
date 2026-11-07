import AppKit
import SwiftUI

/// Stored preferences.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: "saveFolder") }
    }
    @Published var keepTestTracks: Bool {
        didSet { defaults.set(keepTestTracks, forKey: "keepTestTracks") }
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Recordings", isDirectory: true)
    }

    private init() {
        if let path = defaults.string(forKey: "saveFolder"), !path.isEmpty {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = Self.defaultFolder
        }
        keepTestTracks = defaults.bool(forKey: "keepTestTracks")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save recordings"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        panel.directoryURL = saveFolder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url
        }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save recordings to")
                        .font(.headline)
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath(settings.saveFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.saveFolder.path)
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    HStack {
                        Button("Change…") { settings.chooseFolder() }
                        Button("Show in Finder") { settings.revealFolder() }
                        Spacer()
                        Button("Use Default") { settings.saveFolder = AppSettings.defaultFolder }
                            .disabled(settings.saveFolder == AppSettings.defaultFolder)
                    }
                }
            }
            Section {
                Toggle("Also save separate test tracks", isOn: $settings.keepTestTracks)
                Text("For tuning only. Saves your raw microphone, the cleaned microphone and the call audio as separate files in a folder next to the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Echo Recorder \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
