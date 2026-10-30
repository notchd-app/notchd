import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One per screen: owns the panel, tracks the mouse and turns scroll/drag events into notch state.
final class NotchController {
    let screen: NSScreen
    let model: NotchModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var closeWork: DispatchWorkItem?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var scrollY: CGFloat = 0
    private var scrollX: CGFloat = 0
    private var scrollConsumed = false

    // Big enough for the open notch plus its shadow and spring overshoot.
    private static let windowHeight: CGFloat = 280

    init(screen: NSScreen) {
        self.screen = screen
        model = NotchModel(screen: screen)
        // Full screen width: the open notch grows with its widgets. Clicks outside the shape pass through anyway.
        let size = CGSize(width: screen.frame.width, height: Self.windowHeight)
        panel = NotchPanel(frame: NSRect(x: screen.frame.midX - size.width / 2,
                                         y: screen.frame.maxY - size.height,
                                         width: size.width, height: size.height))
        let host = FirstMouseHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.ignoresMouseEvents = true
        if !CaptureManager.shared.isActive { panel.orderFrontRegardless() }
        observers.append(NotificationCenter.default.addObserver(forName: .captureVisibilityChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if CaptureManager.shared.isActive { panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .captureSaved, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["displayID"] as? CGDirectDisplayID == model.displayID else { return }
            withAnimation(.notchOpen) {
                self.model.tab = .tray
                self.model.state = .open
                self.model.locked = true
            }
        })

        // ⇧⌘V: open the clipboard on the screen under the pointer and take the keyboard.
        observers.append(NotificationCenter.default.addObserver(forName: .showClipboard, object: nil, queue: .main) { [weak self] _ in
            guard let self, screen.frame.contains(NSEvent.mouseLocation) else { return }
            withAnimation(.notchOpen) {
                self.model.tab = .clipboard
                self.model.state = .open
            }
            model.locked = true
            ClipboardStore.shared.query = ""
            ClipboardStore.shared.selection = ClipboardStore.shared.visible.first?.id
            panel.ignoresMouseEvents = false
            panel.makeKey()
        })
        // Losing the keyboard to another window also ends typing in a task, timer or note field.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            guard !hitRect.contains(mouse) else { return }
            endTyping()
            updateHover(mouse)
        })
        // Clicking another app dismisses the history opened with ⇧⌘V (it's pinned open until then).
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            guard let self, model.isOpen, model.tab == .clipboard, ClipboardShortcut.shared.previousApp != nil else { return }
            closeClipboard()
        })

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.handle($0) } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel)) { [weak self] event in
            self?.handle(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel, handleTrayKey(event) || handleClipboardKey(event) else { return event }
            return nil
        } as Any)
    }

    /// Renders the notch window's top-centre into a PNG, for checking layouts during development.
    func snapshot(to path: String) {
        guard let view = panel.contentView else { return }
        // Animations stall while the display sleeps, so also note what the notch is showing.
        try? String(describing: ActivityCenter.shared.current(for: model))
            .write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        let size = model.isOpen ? model.openSize : model.size(activity: ActivityCenter.shared.current(for: model))
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY - size.height - 20
        let rect = NSRect(x: view.bounds.midX - size.width / 2 - 40, y: top, width: size.width + 80, height: size.height + 20)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return NSLog("[Snapshot] no bitmap") }
        view.cacheDisplay(in: rect, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            NSLog("[Snapshot] \(error)")
        }
    }

    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.close()
    }

    /// Visible shape in screen coordinates, padded so the closed notch is easy to hit.
    private var hitRect: NSRect {
        guard !model.hiddenByFullscreen, !CaptureManager.shared.isActive else { return .zero }
        let size = model.size(activity: ActivityCenter.shared.current(for: model))
        let pad: CGFloat = model.isOpen ? 4 : 10
        return NSRect(x: screen.frame.midX - size.width / 2 - pad,
                      y: screen.frame.maxY - size.height - pad,
                      width: size.width + 2 * pad, height: size.height + pad + 1)
    }

    private func handle(_ event: NSEvent) {
        guard !CaptureManager.shared.isActive else { return }
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) || model.isOpen || model.hovering else { return }

        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            // Clicking anywhere outside the notch (another app, another screen) ends typing,
            // so "Don't close while typing" doesn't pin it open after you've moved on.
            if event.window !== panel, !hitRect.contains(mouse) { endTyping() }
        case .leftMouseDragged:
            detectFileDrag(at: mouse)
            collapseDropZonesIfLeft(at: mouse)
        case .leftMouseUp where model.dropping || model.arrangingWidgets:
            endDrag()
        case .mouseMoved where (model.dropping || model.arrangingWidgets) && NSEvent.pressedMouseButtons & 1 == 0:
            // The drag ended without us seeing its mouse-up (dropped on another app): don't stay stuck open.
            endDrag()
        case .scrollWheel:
            guard Self.scrollTargetsNotch(window: event.window, panel: panel,
                                          location: event.locationInWindow, hitRect: hitRect) else { return }
            handleScroll(event)
        default:
            break
        }
        updateHover(mouse)
    }

    /// Local monitors see every app window. Only the panel under this event may act on it,
    /// even when another screen's notch is pinned open.
    static func scrollTargetsNotch(window: NSWindow?, panel: NSWindow, location: NSPoint, hitRect: NSRect) -> Bool {
        window === panel && hitRect.contains(panel.convertPoint(toScreen: location))
    }

    private func updateHover(_ mouse: NSPoint) {
        let inside = hitRect.contains(mouse)
        panel.ignoresMouseEvents = !(inside || model.dropping || model.arrangingWidgets)
        model.setHovering(inside)
        let prefs = Settings.shared.prefs
        if inside, prefs.alwaysOpenOnHover { model.open() }

        if inside || model.locked || model.dropping || model.arrangingWidgets || prefs.demoMode || (model.typing && prefs.preventCloseWhenTyping) {
            closeWork?.cancel()
            closeWork = nil
        } else if model.isOpen, closeWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.closeWork = nil
                self?.model.close()
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// Drops keyboard focus from the notch's text fields; their focus handlers then clear `model.typing`.
    private func endTyping() {
        guard model.typing else { return }
        panel.makeFirstResponder(nil)
        model.typing = false
    }

    /// Give the drop a moment to land before closing.
    private func endDrag() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // A new drag started in the meantime: leave its drop zones up.
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            model.dropping = false
            model.dropTarget = nil
            model.arrangingWidgets = false
            if !model.hovering { model.close() }
        }
    }

    /// Dragging back away from the drop zones folds the notch up again; coming back reopens it.
    private func collapseDropZonesIfLeft(at mouse: NSPoint) {
        guard model.dropping, model.isOpen, !model.locked else { return }
        let size = model.openSize
        let area = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height).insetBy(dx: -60, dy: -60)
        guard !area.contains(mouse) else { return }
        model.close()  // also clears `dropping`, so detectFileDrag can open it again
    }

    private func detectFileDrag(at mouse: NSPoint) {
        let pasteboard = NSPasteboard(name: .drag)
        guard !model.dropping, !model.arrangingWidgets, pasteboard.changeCount != dragChangeCount else { return }
        let zone = NSRect(x: screen.frame.midX - 200, y: screen.frame.maxY - 90, width: 400, height: 90)
        guard zone.contains(mouse) else { return }
        if pasteboard.types?.contains(NSPasteboard.PasteboardType("app.notchd.widget")) == true {
            model.arrangingWidgets = true
            model.tab = .nook
        } else if pasteboard.types?.contains(where: Self.droppableTypes.contains) == true {
            model.dropping = true
        } else { return }
        model.open()
    }

    /// Files, links, text, images, and files promised by apps like Photos or Mail.
    private static let droppableTypes: [NSPasteboard.PasteboardType] = {
        let promised = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return [.fileURL, .URL, .string, .tiff, .png] + promised
    }()

    /// Finder-style shortcuts in the Tray tab. Returns true when the key was handled.
    private func handleTrayKey(_ event: NSEvent) -> Bool {
        guard model.isOpen, model.tab == .tray, !model.dropping, !model.typing else { return false }
        let store = TrayStore.shared
        let selected = store.files.filter(store.selection.contains)
        let command = event.modifierFlags.contains(.command)
        switch (command, event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case (true, _, 51) where event.modifierFlags.contains(.shift): store.clear()  // ⇧⌘⌫ clears the tray
        case (true, "v", _): store.paste()
        case (true, "c", _): store.copyToPasteboard(selected)
        case (true, "a", _): store.selection = Set(store.files)
        case (_, _, 51), (_, _, 117): store.remove(selected)       // delete, forward delete
        case (false, " ", _): store.previewURL = selected.first ?? store.files.first
        case (false, _, 36) where selected.count == 1: store.renaming = selected[0]  // return
        case (false, _, 53): store.selection = []                  // escape
        default: return false
        }
        Haptics.tap()
        return true
    }

    /// Arrows pick a card, Return uses it, Delete removes it, Escape closes. Typing goes to the search field.
    private func handleClipboardKey(_ event: NSEvent) -> Bool {
        guard model.isOpen, model.tab == .clipboard, !model.dropping else { return false }
        let store = ClipboardStore.shared
        switch event.keyCode {
        case 123: store.moveSelection(by: -1)                      // left
        case 124: store.moveSelection(by: 1)                       // right
        case 36, 76:                                               // return, enter
            guard let item = store.selectedItem else { return false }
            if Settings.shared.prefs.clipboardPasteOnClick || ClipboardShortcut.shared.previousApp != nil {
                let target = ClipboardShortcut.shared.targetApp()
                closeClipboard()
                store.paste(item, into: target)
            } else {
                store.copy(item)
                model.copiedFlash = item.id
            }
        case 51 where !model.typing, 117:                          // delete, forward delete
            guard let item = store.selectedItem else { return false }
            store.moveSelection(by: 1)
            store.delete(item)
        case 53:                                                   // escape
            closeClipboard()
            ClipboardShortcut.shared.previousApp?.activate()
        default:
            return false
        }
        Haptics.tap()
        return true
    }

    private func closeClipboard() {
        model.locked = false
        model.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ClipboardShortcut.shared.clearPrevious() }
    }

    /// Scrolling a list or a timer wheel in the open notch must not close it.
    private func isOverScrollView(_ event: NSEvent) -> Bool {
        guard model.isOpen, let content = panel.contentView else { return false }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is NSScrollView { return true }
            view = current.superview
        }
        return false
    }

    /// Trackpad: fingers down opens, fingers up closes (or hides an activity); sideways changes track.
    private func handleScroll(_ event: NSEvent) {
        let prefs = Settings.shared.prefs
        guard prefs.allowGestures, !isOverScrollView(event) else { return }
        if event.phase == .began { scrollX = 0; scrollY = 0; scrollConsumed = false }
        guard !scrollConsumed, event.phase != [] else { return }
        let natural: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        scrollY += event.scrollingDeltaY * natural  // > 0: fingers moving down
        scrollX += event.scrollingDeltaX * natural  // > 0: fingers moving right

        // Only act on a clearly dominant axis, so diagonal swipes don't do both.
        if abs(scrollX) > 40, abs(scrollX) > 2 * abs(scrollY) {
            scrollConsumed = true
            changeTrack(fingersRight: scrollX > 0)
            return
        }
        guard prefs.gestureOpenClose, abs(scrollY) > 20, abs(scrollY) > abs(scrollX) else { return }
        scrollConsumed = true
        let activities = ActivityCenter.shared
        if scrollY > 0, !model.isOpen {
            // Swipe down brings back activities hidden for good (Unhide automatically off) before opening.
            if activities.hasDismissed, !prefs.unhideAutomatically { activities.unhideAll() } else { model.open() }
        } else if scrollY < 0, model.isOpen {
            model.close()
        } else if scrollY < 0, let activity = activities.current(for: model) {
            activities.dismiss(activity)
            Haptics.tap()
        }
    }

    /// A left swipe goes back, a right swipe skips; "Invert" flips it.
    private func changeTrack(fingersRight: Bool) {
        let prefs = Settings.shared.prefs
        guard prefs.gestureControlMedia, MediaManager.shared.nowPlaying != nil else { return }
        if fingersRight != prefs.invertMediaGestures { MediaManager.shared.next() } else { MediaManager.shared.previous() }
        Haptics.tap()
        if !model.isOpen { ActivityCenter.shared.peek() }
    }
}
