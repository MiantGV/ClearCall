import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let settings = AppSettings.shared
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var startedAt: Date?
    private var lastRecording: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording {
            let done = DispatchSemaphore(value: 0)
            recorder.stop { _ in done.signal() }
            _ = done.wait(timeout: .now() + 3)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if recorder.isRecording {
            menu.addItem(item("Stop Recording", #selector(toggleRecording), key: "r"))
        } else {
            menu.addItem(item("Start Recording", #selector(toggleRecording), key: "r"))
        }
        menu.addItem(.separator())
        if lastRecording != nil {
            menu.addItem(item("Show Last Recording", #selector(showLastRecording)))
        }
        menu.addItem(item("Open Recordings Folder", #selector(openFolder)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit ClearCall", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func toggleRecording() {
        recorder.isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        MicCapture.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showAlert("Microphone access is off",
                               "Allow ClearCall in System Settings → Privacy & Security → Microphone, then try again.",
                               settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
            do {
                try self.recorder.start(in: self.settings.saveFolder, keepTestTracks: self.settings.keepTestTracks,
                                        echoCancellation: self.settings.echoCancellation)
                self.startedAt = Date()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateIcon() }
                self.updateIcon()
            } catch {
                self.showAlert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        updateIcon()
        recorder.stop { [weak self] result in
            guard let self, let result else { return }
            self.lastRecording = result.file
            if result.systemAudioWasSilent && result.duration > 5 {
                self.showAlert("The call audio was silent",
                               "Your voice was recorded, but nothing playing on the Mac was. If you were on a call, allow ClearCall in System Settings → Privacy & Security → Screen & System Audio Recording (under \"System Audio Recording Only\"), then quit and reopen ClearCall.",
                               settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }

    @objc private func showLastRecording() {
        guard let url = lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openFolder() { settings.revealFolder() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "ClearCall Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if let startedAt {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = image?.withSymbolConfiguration(config)
            let s = Int(Date().timeIntervalSince(startedAt))
            button.title = s >= 3600
                ? String(format: " %d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                : String(format: " %02d:%02d", s / 60, s % 60)
        } else {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "ClearCall")
            button.title = ""
        }
    }

    private func showAlert(_ title: String, _ text: String, settingsURL: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if settingsURL != nil { alert.addButton(withTitle: "Open System Settings") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let s = settingsURL, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
