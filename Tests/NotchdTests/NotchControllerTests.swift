import AppKit
@testable import Notchd
import SwiftUI
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

@Test @MainActor func scrollingTheTrayIsNotATrackSwipe() {
    _ = NSApplication.shared
    // The notch's content view is a hosting view, which is flipped.
    #expect(NSHostingView(rootView: EmptyView()).isFlipped)

    final class Flipped: NSView { override var isFlipped: Bool { true } }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 280), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
    window.contentView = content
    // A row of files 40–150 pt from the top, like the Tray's.
    content.addSubview(NSScrollView(frame: NSRect(x: 0, y: 40, width: 400, height: 110)))

    // Window coordinates count from the bottom: 100 pt from the top is y = 180.
    #expect(NotchController.scrollViewContains(NSPoint(x: 200, y: 180), in: content))
    #expect(!NotchController.scrollViewContains(NSPoint(x: 200, y: 30), in: content))
}
