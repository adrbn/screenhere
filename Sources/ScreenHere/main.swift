import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; menu-bar only
app.run()
