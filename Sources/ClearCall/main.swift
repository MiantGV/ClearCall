import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)     // Dock icon while the window is open; menu-bar only once closed
app.run()
