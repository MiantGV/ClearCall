import AppKit

let app = NSApplication.shared
if Updater.runSelfTestIfRequested() { exit(0) }
if MainActor.assumeIsolated({ PreviewRenderer.runIfRequested() }) { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)     // Dock icon while the window is open; menu-bar only once closed
app.run()
