import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = AppController.shared
    private let settings = AppSettings.shared
    private let prompts = PromptPanel()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.stateChanged() }
        controller.showCallPrompt = { [weak self] call in
            self?.prompts.showCallStarted(call) { self?.controller.start(source: call.appName) }
        }
        controller.showSavedNotice = { [weak self] file, source in
            self?.prompts.showSaved(file, source: source) { self?.controller.reveal(file) }
        }
        controller.hidePrompts = { [weak self] in self?.prompts.hide() }
        controller.showAlert = { [weak self] title, text, url in self?.showAlert(title, text, settingsURL: url) }

        controller.launch()
        updateIcon()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopForQuit()
    }

    // MARK: Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainView(openSettings: { [weak self] in self?.openSettings() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ClearCall"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("ClearCallMain")
            if !window.setFrameUsingName("ClearCallMain") { window.center() }
            mainWindow = window
        }
        // Show a Dock icon while the window is open, so it can be found with ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        // Back to a menu-bar-only app; recording and call detection keep running.
        DispatchQueue.main.async {
            if self.settingsWindow?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
        }
    }

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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(controller.isRecording ? "Stop Recording" : "Start Recording", #selector(toggleRecording), key: "r"))
        if let call = controller.activeCall, !controller.isRecording {
            let info = NSMenuItem(title: "Call in progress: \(call.appName)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        menu.addItem(item("Show ClearCall Window", #selector(showMainWindow)))
        if controller.lastSaved != nil {
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

    @objc private func toggleRecording() { controller.toggle() }

    @objc private func showLastRecording() {
        if let url = controller.lastSaved { controller.reveal(url) }
    }

    @objc private func openFolder() { settings.revealFolder() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Menu bar icon

    private func stateChanged() {
        timer?.invalidate()
        timer = nil
        if controller.isRecording {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateIcon() }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if let startedAt = controller.startedAt {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = image?.withSymbolConfiguration(config)
            let s = Int(Date().timeIntervalSince(startedAt))
            button.title = s >= 3600
                ? String(format: " %d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                : String(format: " %02d:%02d", s / 60, s % 60)
        } else {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "ClearCall")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            image?.accessibilityDescription = "ClearCall"
            button.image = image
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
