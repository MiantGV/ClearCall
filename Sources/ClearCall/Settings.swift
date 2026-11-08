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
    @Published var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: "echoCancellation") }
    }

    enum CallStartAction: String, CaseIterable, Identifiable {
        case ask, record, nothing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: return "Ask me to record"
            case .record: return "Start recording automatically"
            case .nothing: return "Do nothing"
            }
        }
    }
    @Published var callStartAction: CallStartAction {
        didSet { defaults.set(callStartAction.rawValue, forKey: "callStartAction") }
    }
    @Published var stopWhenCallEnds: Bool {
        didSet { defaults.set(stopWhenCallEnds, forKey: "stopWhenCallEnds") }
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
        echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? true
        callStartAction = CallStartAction(rawValue: defaults.string(forKey: "callStartAction") ?? "") ?? .ask
        stopWhenCallEnds = defaults.object(forKey: "stopWhenCallEnds") as? Bool ?? true
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

struct UpdateRow: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ClearCall \(updater.currentVersion)")
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            }
            Spacer()
            if let release = updater.availableRelease {
                Button("Update to \(release.version)") { updater.install() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Check for Updates") { updater.check() }
                    .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
            }
        }
    }

    private var isError: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var statusText: String {
        switch updater.state {
        case .idle: return "Checks for updates automatically."
        case .checking: return "Checking…"
        case .upToDate: return "You have the latest version."
        case .available(let r): return "Version \(r.version) is available."
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing — ClearCall will reopen."
        case .failed(let message): return message
        }
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
            Section("Calls") {
                Picker("When a call starts", selection: $settings.callStartAction) {
                    ForEach(AppSettings.CallStartAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Stop recording when the call ends", isOn: $settings.stopWhenCallEnds)
                HStack {
                    Text("The \"Record?\" card appears at the bottom of the screen. Drag it to move it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Position") { PromptPanel.resetPosition() }
                        .controlSize(.small)
                }
                Text("ClearCall notices calls in WhatsApp, Teams, Zoom, FaceTime, Slack, Discord, Webex, Telegram and browsers (Google Meet and other web calls).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Remove echo (for calls on speakers)", isOn: $settings.echoCancellation)
                Text("Removes the other person's voice from your microphone so it isn't recorded twice. Your voice level is always adjusted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Also save separate test tracks", isOn: $settings.keepTestTracks)
                Text("For tuning only. Saves your raw microphone, the cleaned microphone and the call audio as separate files in a folder next to the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                UpdateRow()
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
