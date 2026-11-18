import AppKit
import ImageIO
import ApplicationServices
import CryptoKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Model

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, image, files }

    var id = UUID()
    var kind: Kind
    /// Text and links; for images, the text Vision found in them (searchable, copyable).
    var text: String?
    var files: [String]?
    /// PNG in the clipboard folder, by file name.
    var imageFile: String?
    /// Fingerprint of the image, so copying the same picture twice keeps one card.
    var imageHash: String?
    var sourceApp: String?
    var date = Date()
    var pinned = false

    /// What two copies of the same thing have in common, so copying it again moves it up instead of duplicating it.
    var contentKey: String {
        switch kind {
        case .text, .link: "\(kind.rawValue):\(text ?? "")"
        case .files: "files:\((files ?? []).joined(separator: "\n"))"
        case .image: "image:\(imageHash ?? imageFile ?? id.uuidString)"
        }
    }

    var fileURLs: [URL] { (files ?? []).map { URL(fileURLWithPath: $0) } }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [text, files?.map { ($0 as NSString).lastPathComponent }.joined(separator: " "),
                        sourceApp.map(MediaManager.appName)].compactMap { $0 }.joined(separator: " ")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Clipboard history: watches the general pasteboard, keeps what you copy, and puts it back on request.
/// Items marked concealed or transient (password managers do this) are never recorded.
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()
    static let defaultIgnoredApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                                     "com.apple.Passwords", "com.bitwarden.desktop", "com.lastpass.LastPass",
                                     "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop"]

    /// Names for the default list, shown even when the app isn't installed.
    static func appName(_ id: String) -> String {
        let known = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                     "com.lastpass.LastPass": "LastPass", "com.dashlane.dashlanephonefinal": "Dashlane",
                     "in.sinew.Enpass-Desktop": "Enpass", "com.bitwarden.desktop": "Bitwarden"]
        let name = MediaManager.appName(id)
        return name == id ? known[id] ?? id : name
    }

    private(set) var items: [ClipItem] = []
    /// Card picked with the arrow keys (or hovered last).
    var selection: UUID?
    var query = ""

    private let folder: URL
    private let index: URL
    private let pasteboard: NSPasteboard
    private var lastChange: Int
    private var ownChange: Int?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    init(folder: URL = URL.appSupport.appendingPathComponent("Clipboard", isDirectory: true),
         pasteboard: NSPasteboard = .general) {
        self.folder = folder
        self.pasteboard = pasteboard
        index = folder.appendingPathComponent("history.json")
        lastChange = pasteboard.changeCount
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        items = Stored.load([ClipItem].self, from: index) ?? []
    }

    /// Starts or stops watching to follow the setting.
    func apply() {
        let on = Settings.shared.prefs.clipboardEnabled
        if on, timer == nil {
            lastChange = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        } else if !on, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Pinned first, then newest, filtered by the search field.
    var visible: [ClipItem] {
        items.filter { $0.matches(query) }.sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
    }

    func imageURL(_ item: ClipItem) -> URL? { item.imageFile.map { folder.appendingPathComponent($0) } }

    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()

    /// Small, cached preview for a card: decoding full screenshots on every redraw would be slow.
    func thumbnail(_ item: ClipItem) -> NSImage? {
        guard let name = item.imageFile, let url = imageURL(item) else { return nil }
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 360,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        thumbnails.setObject(image, forKey: name as NSString)
        return image
    }

    // MARK: Recording

    func poll() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if change == ownChange { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ignored = Settings.shared.prefs.clipboardIgnoredApps
        let folder = folder, pasteboard = pasteboard
        // Off the main thread: apps hand over what was copied only when asked, so a busy or frozen app
        // (or a huge image) would otherwise freeze the notch until it answers.
        Self.readQueue.async { [weak self] in
            guard let item = Self.read(pasteboard, source: source, ignoredApps: ignored, imageFolder: folder) else { return }
            // Something else was copied while we were reading: this one is already history.
            guard pasteboard.changeCount == change else {
                if let name = item.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
                return
            }
            DispatchQueue.main.async { self?.record(item) }
        }
    }

    private static let readQueue = DispatchQueue(label: "notchd.clipboard.read", qos: .utility)
    private static let writeQueue = DispatchQueue(label: "notchd.clipboard.write", qos: .utility)
    /// Longer text isn't kept: a copied log or database dump would slow every later copy and search.
    static let maxTextBytes = 1_000_000
    static let maxImageBytes = 80_000_000

    /// No files and no text: the copy is a picture.
    static func isImageOnly(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
        else { return false }
        return !types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) && pasteboard.string(forType: .string) == nil
    }

    static func allowed(_ pasteboard: NSPasteboard, source: String?, ignoredApps: [String]) -> Bool {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !types.isEmpty, types.isDisjoint(with: privateTypes) else { return false }
        if let source, ignoredApps.contains(source) { return false }
        return true
    }

    /// PNG-encodes, fingerprints and saves a copied picture.
    static func imageItem(_ raw: Data, source: String?, folder: URL) -> ClipItem? {
        guard let rep = NSBitmapImageRep(data: raw), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return nil }
        let hash = SHA256.hash(data: png).prefix(16).map { String(format: "%02x", $0) }.joined()
        return ClipItem(kind: .image, imageFile: name, imageHash: hash, sourceApp: source)
    }

    /// Markers from nspasteboard.org that apps set on secrets and throwaway data.
    static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                            "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    /// What's on the pasteboard as a history item, or nil when it shouldn't be kept.
    static func read(_ pasteboard: NSPasteboard, source: String?, ignoredApps: [String], imageFolder: URL) -> ClipItem? {
        guard allowed(pasteboard, source: source, ignoredApps: ignoredApps) else { return nil }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClipItem(kind: .files, files: urls.map(\.path), sourceApp: source)
        }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard string.utf8.count <= maxTextBytes else { return nil }
            return ClipItem(kind: isLink(string) ? .link : .text, text: string, sourceApp: source)
        }
        if types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue),
           let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), raw.count <= maxImageBytes {
            return imageItem(raw, source: source, folder: imageFolder)
        }
        return nil
    }

    static func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    func record(_ item: ClipItem) {
        var item = item
        if let i = items.firstIndex(where: { $0.contentKey == item.contentKey }) {
            // Same thing again: move it up, keep its pin.
            item.pinned = items[i].pinned
            item.id = items[i].id
            item.text = item.text ?? items[i].text
            removeImage(of: items[i], keeping: item.imageFile)
            items.remove(at: i)
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { items.insert(item, at: 0) }
        trim()
        scheduleSave()
        if item.kind == .image, item.text == nil { recognizeText(in: item) }
    }

    /// Unpinned items beyond the limit go, oldest first.
    private func trim() {
        let limit = Int(Settings.shared.prefs.clipboardLimit)
        var unpinned = 0
        var kept: [ClipItem] = []
        for item in items.sorted(by: { $0.date > $1.date }) {
            if item.pinned { kept.append(item); continue }
            unpinned += 1
            if unpinned <= limit { kept.append(item) } else { removeImage(of: item) }
        }
        if kept.count != items.count { items = items.filter { item in kept.contains { $0.id == item.id } } }
    }

    /// Images are made searchable by the words in them (screenshots of code, receipts, slides…).
    private func recognizeText(in item: ClipItem) {
        guard let url = imageURL(item) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(url: url).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[i].text = text
                self.scheduleSave()
            }
        }
    }

    // MARK: Using items

    /// Puts an item back on the pasteboard (and to the top of the list).
    func copy(_ item: ClipItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .link:
            if let url = URL(string: item.text ?? "") { pasteboard.writeObjects([url as NSURL]) }
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = imageURL(item), let image = NSImage(contentsOf: url) { pasteboard.writeObjects([image]) }
        case .files:
            pasteboard.writeObjects(item.fileURLs as [NSURL])
        }
        ownChange = pasteboard.changeCount
        lastChange = pasteboard.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { items[i].date = Date() }
            scheduleSave()
        }
    }

    func copyText(_ item: ClipItem) {
        guard let text = item.text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies, then types ⌘V into the app you were using. Needs Accessibility; asks for it the first time.
    func paste(_ item: ClipItem, into app: NSRunningApplication?) {
        copy(item)
        guard Self.canPaste(prompt: true) else { return }
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func canPaste(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { items[i].pinned.toggle() }
        trim()
        scheduleSave()
    }

    func delete(_ item: ClipItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.removeAll { $0.id == item.id } }
        removeImage(of: item)
        if selection == item.id { selection = nil }
        scheduleSave()
    }

    /// Clears the history; pinned items stay unless `includingPinned`.
    func clear(includingPinned: Bool = false) {
        let gone = items.filter { includingPinned || !$0.pinned }
        gone.forEach { removeImage(of: $0) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.removeAll { includingPinned || !$0.pinned } }
        selection = nil
        scheduleSave()
    }

    func addToTray(_ item: ClipItem) {
        switch item.kind {
        case .text: TrayStore.shared.add(text: item.text ?? "")
        case .link: if let url = URL(string: item.text ?? "") { TrayStore.shared.add(link: url) }
        case .image: if let url = imageURL(item), let image = NSImage(contentsOf: url) { TrayStore.shared.add(image: image) }
        case .files: TrayStore.shared.add(item.fileURLs)
        }
    }

    /// Moves the keyboard selection through the visible cards.
    func moveSelection(by offset: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : list.count)
        selection = list[min(max(current + offset, 0), list.count - 1)].id
    }

    var selectedItem: ClipItem? { visible.first { $0.id == selection } ?? visible.first }

    private func removeImage(of item: ClipItem, keeping keep: String? = nil) {
        guard let name = item.imageFile, name != keep else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Encodes and writes in the background; `wait` (at quit) returns once it's on disk.
    func save(wait: Bool = false) {
        saveWork?.cancel()
        let items = items, index = index
        let write = { try? JSONEncoder().encode(items).write(to: index, options: .atomic) }
        if wait { Self.writeQueue.sync { _ = write() } } else { Self.writeQueue.async { _ = write() } }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Global shortcut

/// A system-wide shortcut through Carbon's hot keys: no Accessibility permission needed.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.id = id
        Self.installHandler()
        Self.handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x6E746368), id: id)  // 'ntch'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension Notification.Name {
    /// Opens the clipboard tab on the screen under the pointer, ready for the keyboard.
    static let showClipboard = Notification.Name("notchd.showClipboard")
}

/// ⇧⌘V opens the clipboard history from anywhere.
final class ClipboardShortcut {
    static let shared = ClipboardShortcut()
    private var hotKey: HotKey?
    /// The app you were in when you pressed the shortcut: pasting goes back to it.
    private(set) var previousApp: NSRunningApplication?

    func apply() {
        let prefs = Settings.shared.prefs
        if prefs.clipboardEnabled, prefs.clipboardShortcut {
            guard hotKey == nil else { return }
            hotKey = HotKey(id: 1, keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) { [weak self] in self?.fire() }
        } else {
            hotKey = nil
        }
    }

    func clearPrevious() { previousApp = nil }

    private func fire() {
        previousApp = NSWorkspace.shared.frontmostApplication
        NotificationCenter.default.post(name: .showClipboard, object: nil)
    }

    /// Clicking a card in the notch (no shortcut involved) pastes into the app that's in front.
    func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return previousApp }
        return front
    }
}

// MARK: - Views

struct ClipboardView: View {
    @Bindable var model: NotchModel
    @Bindable private var store = ClipboardStore.shared
    @FocusState private var searching: Bool
    @Local private var confirmingClear = false

    init(model: NotchModel) { self.model = model }

    var body: some View {
        let items = store.visible
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard", text: $store.query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit { if let item = store.selectedItem { use(item) } }
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Pill().fill(.white.opacity(0.08)))
                if !store.items.isEmpty { clearButton }
            }
            if !Settings.shared.prefs.clipboardEnabled {
                placeholder("clipboard", "Clipboard history is off", action: ("Turn On", {
                    Settings.shared.prefs.clipboardEnabled = true
                }))
            } else if items.isEmpty {
                placeholder("doc.on.clipboard", store.query.isEmpty ? "Copy something and it shows up here" : "No matches")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(items) { item in
                                ClipCard(item: item, selected: store.selection == item.id, use: { use(item) })
                                    .id(item.id)
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onChange(of: store.selection) { _, id in
                        guard let id else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .onChange(of: searching) { _, value in model.typing = value }
        .onDisappear { ClipboardShortcut.shared.clearPrevious() }
        .onChange(of: store.query) { store.selection = store.visible.first?.id }
        .onAppear { if store.selection == nil { store.selection = items.first?.id } }
    }

    private func use(_ item: ClipItem) {
        Haptics.tap()
        // Opened with ⇧⌘V: picking an item pastes it back where you were, like the keyboard does.
        if Settings.shared.prefs.clipboardPasteOnClick || ClipboardShortcut.shared.previousApp != nil {
            let target = ClipboardShortcut.shared.targetApp()
            model.locked = false
            model.close()
            store.paste(item, into: target)
        } else {
            store.copy(item)
            model.copiedFlash = item.id
        }
    }

    private func placeholder(_ icon: String, _ text: LocalizedStringKey,
                             action: (LocalizedStringKey, () -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(text).font(.system(size: 11, weight: .medium))
            if let action {
                Button(action: action.1) { Text(action.0) }
                    .buttonStyle(BouncyButtonStyle())
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Pill().fill(.white.opacity(0.12)))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clearButton: some View {
        Button {
            if confirmingClear {
                confirmingClear = false
                store.clear()
                Haptics.tap()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { confirmingClear = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { confirmingClear = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: confirmingClear ? "trash.fill" : "trash")
                if confirmingClear { Text("Clear History?") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(confirmingClear ? .white : .secondary)
            .padding(.horizontal, confirmingClear ? 8 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(Pill().fill(confirmingClear ? Color.red.opacity(0.85) : .white.opacity(0.08)))
        }
        .buttonStyle(BouncyButtonStyle())
        .help("Clear history (pinned items stay)")
    }
}

private struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let use: () -> Void
    private var store: ClipboardStore { .shared }
    @Local private var hovering = false

    var body: some View {
        Button(action: use) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let app = item.sourceApp, let icon = MediaManager.appIcon(app) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                    Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(7)
            .frame(width: 128)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(selected ? 0.16 : hovering ? 0.11 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 1.5))
            .overlay {
                if ClipboardFlash.shared.copied == item.id {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.6))
                        .overlay(Label("Copied", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)))
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
        .onHover { hovering = $0 }
        .onDrag { provider }
        .contextMenu { menu }
        .help(item.kind == .files ? item.fileURLs.map(\.lastPathComponent).joined(separator: ", ") : "")
    }

    private var icon: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            // Four lines are shown: don't lay out (or scan) a megabyte for them.
            let preview = String((item.text ?? "").prefix(600))
            Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10, design: Self.looksLikeCode(preview) ? .monospaced : .default))
                .lineLimit(4)
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: item.text ?? "")?.host() ?? "").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Text(item.text ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
            }
        case .image:
            if let image = store.thumbnail(item) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        case .files:
            HStack(spacing: 5) {
                if let first = item.fileURLs.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileURLs.first?.lastPathComponent ?? "").font(.system(size: 10)).lineLimit(2)
                    if item.fileURLs.count > 1 {
                        Text("+\(item.fileURLs.count - 1) more").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func looksLikeCode(_ text: String) -> Bool {
        let markers = ["{", "}", ";", "=>", "func ", "def ", "let ", "const ", "</", "import "]
        return markers.filter { text.contains($0) }.count >= 2
    }

    private var provider: NSItemProvider {
        switch item.kind {
        case .text: NSItemProvider(object: (item.text ?? "") as NSString)
        case .link: URL(string: item.text ?? "").map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        case .image: store.imageURL(item).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .files: item.fileURLs.first.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Copy") { store.copy(item) }
        Button("Paste") { store.paste(item, into: ClipboardShortcut.shared.targetApp()) }
        if item.kind == .image, item.text != nil {
            Button("Copy Text in Image") { store.copyText(item) }
        }
        if item.kind == .link, let url = URL(string: item.text ?? "") {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .files {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
        }
        Button("Add to Tray") { store.addToTray(item) }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
        Button("Delete", role: .destructive) { store.delete(item) }
    }
}

/// Briefly marks the card you just copied.
@Observable
final class ClipboardFlash {
    static let shared = ClipboardFlash()
    var copied: UUID?
}

extension NotchModel {
    /// Shows "Copied" over a card for a moment.
    var copiedFlash: UUID? {
        get { ClipboardFlash.shared.copied }
        set {
            withAnimation(.easeOut(duration: 0.15)) { ClipboardFlash.shared.copied = newValue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard ClipboardFlash.shared.copied == newValue else { return }
                withAnimation(.easeOut(duration: 0.25)) { ClipboardFlash.shared.copied = nil }
            }
        }
    }
}
