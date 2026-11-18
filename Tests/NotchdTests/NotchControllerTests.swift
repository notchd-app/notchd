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

@Test func sidewaysSwipesOnlySkipTracksOnHomeOrTheClosedNotch() {
    #expect(NotchController.sidewaysSwipeChangesTrack(isOpen: false, tab: .tray, dropping: false))
    #expect(NotchController.sidewaysSwipeChangesTrack(isOpen: true, tab: .nook, dropping: false))
    #expect(!NotchController.sidewaysSwipeChangesTrack(isOpen: true, tab: .tray, dropping: false))
    #expect(!NotchController.sidewaysSwipeChangesTrack(isOpen: true, tab: .clipboard, dropping: false))
    #expect(!NotchController.sidewaysSwipeChangesTrack(isOpen: true, tab: .nook, dropping: true))
}

@Test func volumeKeysAreRecognised() {
    // data1 for "volume up, key down" as macOS sends it: key 0 in the high word, 0x0A = down.
    #expect(HUDCenter.volumeKey(subtype: 8, data1: 0x0000_0A00)?.down == true)
    #expect(HUDCenter.volumeKey(subtype: 8, data1: 0x0001_0B00)?.down == false)   // volume down, key up
    #expect(HUDCenter.volumeKey(subtype: 8, data1: 0x0007_0A00)?.code == 7)       // mute
    #expect(HUDCenter.volumeKey(subtype: 8, data1: 0x0010_0A00) == nil)           // play/pause
    #expect(HUDCenter.volumeKey(subtype: 7, data1: 0x0000_0A00) == nil)
}

@Test func volumeKeysStepLikeMacOS() {
    // Up and down move one of 16 steps and stop at the ends.
    #expect(HUDCenter.volumeAfterKey(0, level: 0.5, muted: false, fine: false).level == 0.5625)
    #expect(HUDCenter.volumeAfterKey(1, level: 0.5, muted: false, fine: false).level == 0.4375)
    #expect(HUDCenter.volumeAfterKey(0, level: 1, muted: false, fine: false).level == 1)
    #expect(HUDCenter.volumeAfterKey(1, level: 0, muted: false, fine: false).level == 0)
    // An in-between level (set with a slider) snaps to the grid first.
    #expect(HUDCenter.volumeAfterKey(0, level: 0.63, muted: false, fine: false).level == 0.6875)
    // ⌥⇧ moves a quarter step.
    #expect(HUDCenter.volumeAfterKey(0, level: 0.5, muted: false, fine: true).level == 0.515625)
    // Mute toggles and keeps the level; volume up while muted only unmutes.
    #expect(HUDCenter.volumeAfterKey(7, level: 0.5, muted: false, fine: false) == (0.5, true))
    #expect(HUDCenter.volumeAfterKey(7, level: 0.5, muted: true, fine: false) == (0.5, false))
    #expect(HUDCenter.volumeAfterKey(0, level: 0.5, muted: true, fine: false) == (0.5, false))
    #expect(HUDCenter.volumeAfterKey(1, level: 0.5, muted: true, fine: false) == (0.4375, true))
}
