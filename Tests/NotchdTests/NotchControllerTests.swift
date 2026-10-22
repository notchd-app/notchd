import AppKit
@testable import Notchd
import Testing

@Test @MainActor func scrollGesturesOnlyReachTheirOwnNotch() {
    _ = NSApplication.shared
    let frame = NSRect(x: 100, y: 200, width: 1000, height: 280)
    let panel = NotchPanel(frame: frame)
    let otherPanel = NotchPanel(frame: frame)
    let settingsWindow = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    settingsWindow.isReleasedWhenClosed = false
    defer { panel.close(); otherPanel.close(); settingsWindow.close() }
    let hitRect = NSRect(x: 500, y: 450, width: 200, height: 30)
    let overNotch = panel.convertPoint(fromScreen: NSPoint(x: 600, y: 465))

    #expect(NotchController.scrollTargetsNotch(window: panel, panel: panel, location: overNotch, hitRect: hitRect))
    // All local monitors see these events, including those belonging to Settings and another notch.
    #expect(!NotchController.scrollTargetsNotch(window: settingsWindow, panel: panel, location: overNotch, hitRect: hitRect))
    #expect(!NotchController.scrollTargetsNotch(window: otherPanel, panel: panel, location: overNotch, hitRect: hitRect))
    #expect(!NotchController.scrollTargetsNotch(window: panel, panel: otherPanel, location: overNotch, hitRect: hitRect))
    #expect(!NotchController.scrollTargetsNotch(window: nil, panel: panel, location: overNotch, hitRect: hitRect))
    // Transparent panel space and a hidden fullscreen notch must not accept gestures.
    #expect(!NotchController.scrollTargetsNotch(window: panel, panel: panel, location: .zero, hitRect: hitRect))
    #expect(!NotchController.scrollTargetsNotch(window: panel, panel: panel, location: overNotch, hitRect: .zero))
}

@Test @MainActor func leavingATabEndsTyping() {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first else { return }  // no display to build a notch for
    let model = NotchModel(screen: screen)

    // Switching tabs removes the focused field without its focus handler running,
    // so "Stay open when the pointer leaves" would pin the notch and the Tray would ignore its keys.
    model.typing = true
    model.tab = .tray
    #expect(!model.typing)

    model.typing = true
    model.tab = .tray
    #expect(model.typing)

    model.tab = .nook
    model.typing = true
    model.dropping = true
    #expect(!model.typing)
}
