import AppKit

// Frevo: app da barra de menu (sem ícone no Dock; LSUIElement no Info.plist).
let app = NSApplication.shared
let controlador = MainActor.assumeIsolated { Controlador() }
app.delegate = controlador
app.setActivationPolicy(.accessory)
app.run()
