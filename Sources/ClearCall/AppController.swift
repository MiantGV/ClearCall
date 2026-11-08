import AVFoundation
import AppKit
import Combine

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let duration: TimeInterval
    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// Shared state and actions for the window, the menu bar and call detection. Main thread only.
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var recordingSource: String?        // e.g. "WhatsApp" when started for a call
    @Published private(set) var activeCall: CallDetector.Call?
    @Published private(set) var recent: [RecordingItem] = []
    @Published private(set) var lastSaved: URL?
    @Published var micLevel: Float = 0
    @Published var callLevel: Float = 0

    let settings = AppSettings.shared
    private let recorder = Recorder()
    private let detector = CallDetector()
    private var cancellables: Set<AnyCancellable> = []

    /// UI hooks set by the app delegate.
    var onStateChange: (() -> Void)?
    var showCallPrompt: ((CallDetector.Call) -> Void)?
    var showSavedNotice: ((URL, String?) -> Void)?
    var hidePrompts: (() -> Void)?
    var showAlert: ((String, String, String?) -> Void)?

    private init() {
        recorder.onLevels = { [weak self] mic, call in
            guard let self, self.isRecording else { return }
            // Smooth falling meters.
            self.micLevel = max(Self.meter(mic), self.micLevel * 0.8)
            self.callLevel = max(Self.meter(call), self.callLevel * 0.8)
        }
        detector.onCallStarted = { [weak self] call in self?.callStarted(call) }
        detector.onCallEnded = { [weak self] call in self?.callEnded(call) }
        settings.$saveFolder.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshRecent() }
        }.store(in: &cancellables)
    }

    func launch() {
        detector.start()
        refreshRecent()
    }

    // MARK: Recording

    func toggle() { isRecording ? stop() : start(source: nil) }

    func start(source: String?) {
        guard !isRecording else { return }
        MicCapture.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showAlert?("Microphone access is off",
                                "Allow ClearCall in System Settings → Privacy & Security → Microphone, then try again.",
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
            do {
                try self.recorder.start(in: self.settings.saveFolder,
                                        keepTestTracks: self.settings.keepTestTracks,
                                        echoCancellation: self.settings.echoCancellation)
                self.isRecording = true
                self.startedAt = Date()
                self.recordingSource = source ?? self.activeCall?.appName
                self.hidePrompts?()
                self.onStateChange?()
            } catch {
                self.showAlert?("Couldn't start recording", error.localizedDescription, nil)
            }
        }
    }

    func stop(announce: Bool = false) {
        guard isRecording else { return }
        let source = recordingSource
        isRecording = false
        startedAt = nil
        recordingSource = nil
        micLevel = 0
        callLevel = 0
        onStateChange?()
        recorder.stop { [weak self] result in
            guard let self, let result else { return }
            self.lastSaved = result.file
            self.refreshRecent()
            if announce { self.showSavedNotice?(result.file, source) }
            if result.systemAudioWasSilent && result.duration > 5 {
                self.showAlert?("The call audio was silent",
                                "Your voice was recorded, but nothing playing on the Mac was. If you were on a call, allow ClearCall in System Settings → Privacy & Security → Screen & System Audio Recording (under \"System Audio Recording Only\"), then quit and reopen ClearCall.",
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }

    /// Stops the recording synchronously (for quitting).
    func stopForQuit() {
        guard isRecording else { return }
        isRecording = false
        let done = DispatchSemaphore(value: 0)
        recorder.stop { _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: Calls

    private func callStarted(_ call: CallDetector.Call) {
        activeCall = call
        onStateChange?()
        guard !isRecording else { return }
        switch settings.callStartAction {
        case .ask: showCallPrompt?(call)
        case .record: start(source: call.appName)
        case .nothing: break
        }
    }

    private func callEnded(_ call: CallDetector.Call) {
        activeCall = nil
        hidePrompts?()
        onStateChange?()
        if isRecording, settings.stopWhenCallEnds, recordingSource == call.appName {
            stop(announce: true)
        }
    }

    // MARK: Recordings list

    func refreshRecent() {
        let folder = settings.saveFolder
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let items: [RecordingItem] = files
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .compactMap { url in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(6)
                .map { url, date in
                    var duration: TimeInterval = 0
                    if let file = try? AVAudioFile(forReading: url) {
                        duration = Double(file.length) / file.processingFormat.sampleRate
                    }
                    return RecordingItem(url: url, date: date, duration: duration)
                }
            DispatchQueue.main.async { self.recent = items }
        }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Peak (0…1) to a meter position, on a 60 dB scale.
    private static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return min(1, max(0, (db + 60) / 60))
    }
}
