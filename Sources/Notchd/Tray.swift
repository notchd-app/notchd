import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

extension URL {
    static let appSupport: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Dropped files live in the tray folder; the folder itself is the persisted state.
@Observable
final class TrayStore {
    static let shared = TrayStore()
    static let defaultFolder = URL.appSupport.appendingPathComponent("TrayFiles", isDirectory: true)

    struct FolderChangeNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private let settings: Settings
    private let fileManager: FileManager
    private(set) var files: [URL] = []
    private(set) var folder: URL
    var folderChangeNotice: FolderChangeNotice?
    /// Files dropped together show as one pile (file names, relative to the folder).
    private(set) var stacks: [[String]] = []
    /// Piles opened up to show their files.
    var expanded: Set<String> = []
    /// Kept in the tray folder (hidden), so piles follow the folder and every tray has its own.
    private var stacksFile: URL { folder.appendingPathComponent(".notchd-stacks.json") }
    var selection: Set<URL> = []
    /// File shown in Quick Look (Space).
    var previewURL: URL?
    /// File whose name is being edited.
    var renaming: URL?
    /// The last tray rule that failed, and why: shown as a banner in the tray until dismissed.
    var ruleError: String?

    convenience init(settings: Settings = .shared) {
        self.init(folder: settings.prefs.trayFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder, settings: settings)
    }

    init(folder: URL, settings: Settings = .shared, fileManager: FileManager = .default) {
        self.folder = folder.standardizedFileURL
        self.settings = settings
        self.fileManager = fileManager
        stacks = (try? JSONDecoder().decode([[String]].self, from: Data(contentsOf: stacksFile))) ?? []
        reload()
        // Auto-clear runs at launch and then hourly.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.autoClear() }
    }

    func reload() {
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        files = ((try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: .skipsHiddenFiles)) ?? [])
            .map(\.standardizedFileURL)
            .sorted { $0.addedDate < $1.addedDate }
        autoClear()
        pruneStacks()
    }

    // MARK: Stacks

    enum Item: Identifiable, Equatable {
        case file(URL), stack([URL])
        var id: String {
            switch self {
            case let .file(url): url.lastPathComponent
            case let .stack(urls): "stack:" + (urls.first?.lastPathComponent ?? "")
            }
        }
        var urls: [URL] {
            switch self {
            case let .file(url): [url]
            case let .stack(urls): urls
            }
        }
    }

    /// What the tray shows: single files, and piles of files dropped together (opened piles show their files).
    var items: [Item] {
        var result: [Item] = []
        var seen = Set<URL>()
        for file in files where !seen.contains(file) {
            if let stack = stacks.first(where: { $0.contains(file.lastPathComponent) }) {
                let urls = files.filter { stack.contains($0.lastPathComponent) }
                seen.formUnion(urls)
                if expanded.contains(stack[0]) { result += urls.map(Item.file) } else { result.append(.stack(urls)) }
            } else {
                result.append(.file(file))
            }
        }
        return result
    }

    /// The pile a file belongs to, by the name of its first file.
    func stackKey(of url: URL) -> String? {
        stacks.first { $0.contains(url.lastPathComponent) }?.first
    }

    func toggleExpanded(_ key: String) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            if expanded.remove(key) == nil { expanded.insert(key) }
        }
    }

    /// Breaks a pile back into single files.
    func unstack(_ key: String) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            stacks.removeAll { $0.first == key }
            expanded.remove(key)
        }
        saveStacks()
    }

    /// "3 PDFs", "4 images" or "5 files".
    static func stackTitle(_ urls: [URL]) -> String {
        let types = Set(urls.compactMap { try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType })
        if types.allSatisfy({ $0.conforms(to: .image) }) { return String(localized: "\(urls.count) images") }
        if types.count == 1, let type = types.first, let ext = type.preferredFilenameExtension {
            return "\(urls.count) \(ext.uppercased())"
        }
        return String(localized: "\(urls.count) files")
    }

    /// Forgets names that left the folder and piles left with fewer than two files.
    private func pruneStacks() {
        let names = Set(files.map(\.lastPathComponent))
        let pruned = stacks.map { $0.filter(names.contains) }.filter { $0.count > 1 }
        if pruned != stacks {
            stacks = pruned
            saveStacks()
        }
    }

    private func saveStacks() {
        try? JSONEncoder().encode(stacks).write(to: stacksFile, options: .atomic)
    }

    func add(_ urls: [URL]) {
        add(urls, move: settings.prefs.trayMoveOnDrop)
    }

    /// Capture output is kept at its staging location until the tray copy succeeds.
    /// This deliberately ignores the user's drag-and-drop move preference.
    @discardableResult
    func importCapture(from source: URL) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".capture-\(UUID().uuidString)")
        let target: URL
        do {
            try fileManager.copyItem(at: source, to: staging)
            target = uniqueTarget(for: source.lastPathComponent, in: folder)
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { files.append(target) }
        selection = [target]
        return target
    }

    private func add(_ urls: [URL], move: Bool) {
        var added: [String] = []
        // Dragging a tray file back onto the tray is a no-op, not a duplicate.
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            let target = uniqueTarget(for: url.lastPathComponent, in: folder)
            // Promised files (from Photos, Mail...) were saved to a temporary folder: take them as they are.
            let temporary = url.path.hasPrefix(DroppedItem.promisesFolder.path)
            do {
                if move || temporary { try fileManager.moveItem(at: url, to: target) }
                else { try fileManager.copyItem(at: url, to: target) }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { files.append(target) }
                added.append(target.lastPathComponent)
            } catch {
                NSLog("[Tray] \(move ? "move" : "copy") failed: \(error)")
            }
        }
        if added.count > 1 {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { stacks.append(added) }
            saveStacks()
        }
        applyRules(added.map { folder.appendingPathComponent($0) })
    }

    /// Rules see what you add (drops, pastes). Action and capture results come in through `importCapture`,
    /// which skips them, so a rule's output can't set off another rule.
    private func applyRules(_ urls: [URL]) {
        guard !urls.isEmpty, !settings.prefs.trayRules.isEmpty else { return }
        TrayRules.process(urls, rules: settings.prefs.trayRules, store: self)
    }

    /// Sends to the Trash rather than deleting: the tray folder may be one the user also uses.
    func remove(_ url: URL) {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { files.removeAll { $0 == url } }
            pruneStacks()
        } catch {
            NSLog("[Tray] trash failed: \(error)")
        }
    }

    /// Sends every tray file to the Trash and forgets selection, piles and previews.
    func clear() {
        remove(files)
        expanded = []
        previewURL = nil
        renaming = nil
    }

    func remove(_ urls: some Sequence<URL>) {
        urls.forEach(remove)
        selection.subtract(urls)
    }

    /// Drops files that vanished from disk (moved out with an Option-drag, deleted in Finder...).
    func reconcile() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            files.removeAll { !fileManager.fileExists(atPath: $0.path) }
        }
        selection.formIntersection(files)
        pruneStacks()
    }

    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return nil }
        let target = uniqueTarget(for: name, in: folder)
        do {
            try fileManager.moveItem(at: url, to: target)
            if let i = files.firstIndex(of: url) { files[i] = target }
            stacks = stacks.map { $0.map { $0 == url.lastPathComponent ? target.lastPathComponent : $0 } }
            if expanded.remove(url.lastPathComponent) != nil { expanded.insert(target.lastPathComponent) }
            saveStacks()
            if selection.remove(url) != nil { selection.insert(target) }
            return target
        } catch {
            NSLog("[Tray] rename failed: \(error)")
            return nil
        }
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// ⌘V: files are copied in; images, links and text become files.
    func paste(from pasteboard: NSPasteboard = .general) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls, move: false)
        } else if let image = NSImage(pasteboard: pasteboard) {
            add(image: image)
        } else if let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL, url.scheme?.hasPrefix("http") == true {
            add(link: url)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            add(text: text)
        } else {
            NSLog("[Tray] Paste: pasteboard contained nothing usable.")
        }
    }

    func add(text: String) {
        write(Data(text.utf8), name: String(localized: "Pasted Text \(Self.stamp())") + ".txt")
    }

    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        write(png, name: String(localized: "Pasted Image \(Self.stamp())") + ".png")
    }

    /// Links become .webloc files, which open in the browser and AirDrop as links.
    func add(link: URL) {
        let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
        let host = link.host() ?? "Link"
        if let plist { write(plist, name: "\(host).webloc") }
    }

    private func write(_ data: Data, name: String) {
        let target = uniqueTarget(for: name, in: folder)
        do {
            try data.write(to: target)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { files.append(target) }
            applyRules([target])
        } catch {
            NSLog("[Tray] Failed to write \(name): \(error)")
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    /// Copies everything before committing the new folder, then removes the originals.
    /// A failed copy never strands files outside the active tray. nil = default folder.
    @discardableResult
    func setFolder(_ newFolder: URL?) -> Bool {
        folderChangeNotice = nil
        let target = (newFolder ?? Self.defaultFolder).standardizedFileURL
        let sourcePath = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard sourcePath != targetPath else { return true }
        // Nested folders would copy the tray into itself or make the old tray a tray item.
        guard !targetPath.starts(with: sourcePath), !sourcePath.starts(with: targetPath) else {
            folderChangeNotice = FolderChangeNotice(title: "Choose a separate folder",
                message: "The new folder must not contain your current tray folder or be inside it. Your tray has not moved.")
            return false
        }

        let originalFolder = folder
        let originals = files
        var staging: URL?
        var destinations: [URL: URL] = [:]
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let temporary = target.appendingPathComponent(".notchd-migration-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            staging = temporary
            for file in originals {
                try fileManager.copyItem(at: file, to: temporary.appendingPathComponent(file.lastPathComponent))
            }
            for file in originals {
                let destination = uniqueTarget(for: file.lastPathComponent, in: target)
                try fileManager.moveItem(at: temporary.appendingPathComponent(file.lastPathComponent), to: destination)
                destinations[file] = URL(fileURLWithPath: destination.path, isDirectory: file.hasDirectoryPath)
            }
        } catch {
            let leftovers = removeMigrationItems(Array(destinations.values) + [staging].compactMap { $0 })
            let cleanup = leftovers.isEmpty ? "" : " Some extra copies could not be removed from \(target.path)."
            folderChangeNotice = FolderChangeNotice(title: "Couldn’t change tray folder",
                message: "Your tray is still in \(originalFolder.path), and all originals have been kept. \(error.localizedDescription)\(cleanup)")
            return false
        }

        // Only change the saved location once every file is available at the destination.
        try? fileManager.removeItem(at: stacksFile)
        folder = target
        // Piles follow their files, which may have been renamed to avoid clashes.
        let renamed = Dictionary(uniqueKeysWithValues: destinations.map { ($0.lastPathComponent, $1.lastPathComponent) })
        stacks = stacks.map { $0.map { renamed[$0] ?? $0 } }
        expanded = []
        if !stacks.isEmpty { saveStacks() }
        settings.prefs.trayFolder = newFolder?.path
        selection = Set(selection.compactMap { destinations[$0] })
        previewURL = previewURL.flatMap { destinations[$0] }
        renaming = nil
        let leftovers = removeMigrationItems(originals + [staging].compactMap { $0 })
        reload()
        if !leftovers.isEmpty {
            folderChangeNotice = FolderChangeNotice(title: "Tray moved; extra copies remain",
                message: "Your files are available in \(target.path). These originals or temporary copies could not be removed:\n\n"
                    + leftovers.map(\.path).joined(separator: "\n"))
        }
        return true
    }

    /// Best-effort cleanup only ever touches migration-owned copies or committed originals.
    private func removeMigrationItems(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            do {
                try fileManager.removeItem(at: url)
                return false
            } catch {
                NSLog("[Tray] migration cleanup failed for \(url.path): \(error)")
                return true
            }
        }
    }

    private func autoClear() {
        let days = settings.prefs.trayAutoClearDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        files.filter { $0.addedDate < cutoff }.forEach(remove)
    }

    private func uniqueTarget(for name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = dir.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return target
    }
}

private extension URL {
    var addedDate: Date {
        (try? resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? .distantPast
    }
}

// MARK: - Dropped items

/// Anything that can be dropped on the notch: files, web links, text or images.
enum DroppedItem {
    case file(URL), link(URL), text(String), image(NSImage)

    static let types: [UTType] = [.fileURL, .url, .image, .plainText, .data]

    /// Where files promised by other apps (Photos, Mail...) are written before going to the tray.
    static let promisesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchdDrops", isDirectory: true)

    /// A real file behind the drag that isn't a plain file URL: a photo, a mail attachment...
    private static func fileType(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
        }
    }

    /// Saves a promised file under its own name before the provider deletes it.
    private static func receive(_ provider: NSItemProvider, type: String, done: @escaping (DroppedItem?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            guard let url else { return done(nil) }
            let folder = promisesFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var name = url.lastPathComponent
            if let suggested = provider.suggestedName, !suggested.isEmpty {
                let ext = url.pathExtension
                name = ext.isEmpty || suggested.hasSuffix("." + ext) ? suggested : "\(suggested).\(ext)"
            }
            let target = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
                done(.file(target))
            } catch {
                NSLog("[Tray] could not receive \(name): \(error)")
                done(nil)
            }
        }
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping ([DroppedItem]) -> Void) {
        let group = DispatchGroup()
        var items = [DroppedItem?](repeating: nil, count: providers.count)
        for (i, provider) in providers.enumerated() {
            // Module drags also conform to data, but must never become promised tray files.
            guard !provider.hasItemConformingToTypeIdentifier(UTType.notchdWidget.identifier) else { continue }
            group.enter()
            let done: (DroppedItem?) -> Void = { item in
                DispatchQueue.main.async { items[i] = item; group.leave() }
            }
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    done(url.map { $0.isFileURL ? .file($0) : .link($0) })
                }
            } else if let type = fileType(of: provider) {
                receive(provider, type: type, done: done)
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in done((image as? NSImage).map { .image($0) }) }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in done(text.map { .text($0) }) }
            } else {
                done(nil)
            }
        }
        group.notify(queue: .main) { completion(items.compactMap { $0 }) }
    }

    /// What AirDrop / sharing services accept.
    var shareable: Any {
        switch self {
        case let .file(url), let .link(url): url
        case let .text(text): text
        case let .image(image): image
        }
    }
}

extension TrayStore {
    func add(_ items: [DroppedItem]) {
        add(items.compactMap { if case let .file(url) = $0 { url } else { nil } })
        for item in items {
            switch item {
            case .file: break
            case let .link(url): add(link: url)
            case let .text(text): add(text: text)
            case let .image(image): add(image: image)
            }
        }
    }
}

// MARK: - Tray tab

struct TrayView: View {
    @Bindable var model: NotchModel
    @Bindable private var store = TrayStore.shared
    @Local private var targeted = false
    @Local private var confirmingClear = false
    /// Bumped on every arm, so an older timer can't disarm a newer confirmation.
    @Local private var clearArm = 0

    init(model: NotchModel) { self.model = model }

    var body: some View {
        Group {
            if store.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24))
                        .symbolEffect(.bounce, value: targeted)
                    Text("Drop files here, or paste with ⌘V")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { item in
                            Group {
                                switch item {
                                case let .file(url): TrayFileView(url: url, model: model)
                                case let .stack(urls): TrayStackView(urls: urls)
                                }
                            }
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
                }
                // Clicking the empty space clears the selection.
                .background(Color.black.opacity(0.001).onTapGesture { store.selection = [] })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(targeted ? 0.5 : 0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if TrayActions.shared.working > 0 {
                    ProgressView().controlSize(.mini).frame(width: 24, height: 20)
                        .help(Text("Working on it…"))
                }
                if !store.files.isEmpty {
                    clearButton.transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Button { store.paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .background(Pill().fill(.white.opacity(0.08)))
                }
                .buttonStyle(BouncyButtonStyle())
                .help("Paste (⌘V)")
            }
            .padding(6)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.files.isEmpty)
        }
        .overlay(alignment: .bottom) {
            if let error = store.ruleError {
                RuleErrorBanner(message: error) { store.ruleError = nil }
                    .padding(8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.ruleError)
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: targeted)
        .onDrop(of: DroppedItem.types, isTargeted: $targeted) { providers in
            DroppedItem.load(providers) { store.add($0) }
            Haptics.tap()
            return true
        }
        .quickLookPreview($store.previewURL, in: store.files)
        .onChange(of: store.files.isEmpty) { _, empty in if empty { confirmingClear = false } }
    }

    /// First click arms it ("Clear All?"), a second click within 3 s empties the tray into the Trash.
    private var clearButton: some View {
        Button {
            if confirmingClear {
                confirmingClear = false
                store.clear()
                Haptics.tap()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { confirmingClear = true }
                clearArm += 1
                let arm = clearArm
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard arm == clearArm else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { confirmingClear = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: confirmingClear ? "trash.fill" : "trash")
                    .contentTransition(.symbolEffect(.replace))
                if confirmingClear {
                    Text("Clear All?").transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(confirmingClear ? .white : .secondary)
            .padding(.horizontal, confirmingClear ? 8 : 0)
            .frame(minWidth: 24, minHeight: 20)
            .background(Pill().fill(confirmingClear ? Color.red.opacity(0.85) : .white.opacity(0.08)))
        }
        .buttonStyle(BouncyButtonStyle())
        .help("Clear All (⇧⌘⌫)")
        .accessibilityLabel(Text("Clear All"))
    }
}

/// "Rule failed" line at the bottom of the tray; it goes away on its own after a while.
private struct RuleErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(BouncyButtonStyle())
            .accessibilityLabel(Text("Dismiss"))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
        .help(Text(message))
        .task(id: message) {
            try? await Task.sleep(for: .seconds(12))
            dismiss()
        }
    }
}

struct TrayFileView: View {
    let url: URL
    @Bindable var model: NotchModel
    private var store = TrayStore.shared
    @Local private var hovering = false
    @Local private var draftName = ""
    @FocusState private var nameFocused: Bool

    init(url: URL, model: NotchModel) {
        self.url = url
        self.model = model
    }

    var body: some View {
        let selected = store.selection.contains(url)
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .overlay(TrayItemInteraction(urls: [url], onClick: click, menu: menu))
                .overlay(alignment: .bottomTrailing) {
                    // Opened pile: a small badge folds it back.
                    if let key = store.stackKey(of: url), key == url.lastPathComponent {
                        Button { store.toggleExpanded(key) } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.accentColor))
                        }
                        .buttonStyle(BouncyButtonStyle())
                        .help(Text("Gather back into a pile"))
                        .offset(x: 4, y: 4)
                    }
                }
            if store.renaming == url {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 10))
                    .frame(width: 72)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.15)))
                    .focused($nameFocused)
                    .onAppear {
                        draftName = url.lastPathComponent
                        nameFocused = true
                    }
                    .onSubmit { store.rename(url, to: draftName) }
                    .onExitCommand { store.renaming = nil }
                    .onChange(of: nameFocused) { _, focused in
                        model.typing = focused
                        if !focused, store.renaming == url { store.rename(url, to: draftName) }
                    }
            } else {
                Text(url.lastPathComponent)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : .clear))
                    .frame(width: 72)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(selected ? 0.16 : hovering ? 0.08 : 0)))
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        .onHover { hovering = $0 }
    }

    /// Finder-like: click selects, ⌘-click toggles, ⇧-click extends, double-click opens.
    private func click(_ modifiers: NSEvent.ModifierFlags, _ count: Int) {
        if count >= 2 {
            NSWorkspace.shared.open(url)
            return
        }
        if modifiers.contains(.command) {
            if store.selection.remove(url) == nil { store.selection.insert(url) }
        } else if modifiers.contains(.shift), let anchor = store.files.firstIndex(where: store.selection.contains),
                  let here = store.files.firstIndex(of: url) {
            store.selection.formUnion(store.files[min(anchor, here)...max(anchor, here)])
        } else {
            store.selection = [url]
        }
    }

    private func menu() -> NSMenu {
        if !store.selection.contains(url) { store.selection = [url] }
        let targets = store.files.filter(store.selection.contains)
        let menu = ClosureMenu()
        menu.add(String(localized: "Open")) { targets.forEach { NSWorkspace.shared.open($0) } }
        menu.add(String(localized: "Quick Look")) { store.previewURL = url }
        menu.add(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        if targets.count == 1 { menu.add(String(localized: "Rename")) { store.renaming = url } }
        menu.add(String(localized: "Copy")) { store.copyToPasteboard(targets) }
        menu.add(String(localized: "Send via AirDrop")) { AirDrop.send(targets) }
        TrayActions.shared.addItems(to: menu, for: targets)
        menu.addItem(.separator())
        menu.add(targets.count == 1 ? String(localized: "Remove from Tray")
                                    : String(localized: "Remove \(targets.count) Items from Tray")) {
            store.remove(targets)
        }
        return menu
    }
}

/// Files dropped together: a fanned pile with a count. Click opens it up; drag takes them all.
struct TrayStackView: View {
    let urls: [URL]
    private var store = TrayStore.shared
    @Local private var hovering = false

    init(urls: [URL]) { self.urls = urls }

    var body: some View {
        let selected = !urls.isEmpty && urls.allSatisfy(store.selection.contains)
        VStack(spacing: 4) {
            ZStack {
                ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(Double(index) * (hovering ? 12 : 7)), anchor: .bottom)
                        .offset(x: CGFloat(index) * (hovering ? 6 : 3))
                }
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topTrailing) {
                Text("\(urls.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 6, y: -4)
            }
            .overlay(TrayItemInteraction(urls: urls, onClick: click, menu: menu))
            Text(TrayStore.stackTitle(urls))
                .font(.system(size: 10))
                .lineLimit(1)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : .clear))
                .frame(width: 72)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(selected ? 0.16 : hovering ? 0.08 : 0)))
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovering)
        .onHover { hovering = $0 }
        .help(Text("Click to open the pile"))
    }

    private var key: String? { urls.first.flatMap(store.stackKey) }

    private func click(_ modifiers: NSEvent.ModifierFlags, _ count: Int) {
        if modifiers.contains(.command) {
            if urls.allSatisfy(store.selection.contains) { store.selection.subtract(urls) } else { store.selection.formUnion(urls) }
        } else if let key {
            store.selection = Set(urls)
            store.toggleExpanded(key)
        }
    }

    private func menu() -> NSMenu {
        store.selection = Set(urls)
        let menu = ClosureMenu()
        menu.add(String(localized: "Open All")) { urls.forEach { NSWorkspace.shared.open($0) } }
        menu.add(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        menu.add(String(localized: "Copy")) { store.copyToPasteboard(urls) }
        menu.add(String(localized: "Send via AirDrop")) { AirDrop.send(urls) }
        if let key { menu.add(String(localized: "Unstack")) { store.unstack(key) } }
        TrayActions.shared.addItems(to: menu, for: urls)
        menu.addItem(.separator())
        menu.add(String(localized: "Remove \(urls.count) Items from Tray")) { store.remove(urls) }
        return menu
    }
}

/// NSMenu whose items run closures.
final class ClosureMenu: NSMenu {
    private var actions: [() -> Void] = []

    func add(_ title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        addItem(item)
    }

    @objc private func run(_ item: NSMenuItem) { actions[item.tag]() }
}

/// AppKit drag source over a tray item: drags every selected file, copies by default and moves with
/// Option (SwiftUI's onDrag can't choose the operation or tell when the drop is done). Plain clicks and
/// right clicks are forwarded.
struct TrayItemInteraction: NSViewRepresentable {
    /// One file, or every file of a pile.
    let urls: [URL]
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.menuProvider = menu
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
        var menuProvider: (() -> NSMenu)?
        private var downEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let url = urls.first else { return }
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                                 event.locationInWindow.y - down.locationInWindow.y)
            guard distance > 3 else { return }
            downEvent = nil
            let store = TrayStore.shared
            let dragged = store.selection.contains(url) ? store.files.filter(store.selection.contains) : urls
            let items = dragged.enumerated().map { index, file in
                let item = NSDraggingItem(pasteboardWriter: file as NSURL)
                let offset = CGFloat(index) * 4
                item.setDraggingFrame(bounds.offsetBy(dx: offset, dy: -offset),
                                      contents: NSWorkspace.shared.icon(forFile: file.path))
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if downEvent != nil { onClick?(event.modifierFlags, event.clickCount) }
            downEvent = nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Moved files are gone from the tray folder now.
            if operation == .move { TrayStore.shared.reconcile() }
        }
    }
}

// MARK: - Drop zones

/// Shown while something is dragged over the notch: stash it in the Tray, or hand it to AirDrop.
/// The zones only draw; `FileDropDelegate` on the root view receives the drop.
struct DropZonesView: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            DropZone(icon: "tray.and.arrow.down.fill", title: "Tray", subtitle: "Keep it for later",
                     targeted: model.dropTarget == .tray)
            DropZone(icon: "dot.radiowaves.left.and.right", title: "AirDrop", subtitle: "Send to a nearby device",
                     targeted: model.dropTarget == .airDrop)
        }
    }
}

/// Lives on the always-present root view. Drop zones that register only once the drag is already over
/// the panel sometimes never get `draggingEntered`, so a zone could ignore the drag until you left and came back.
/// The two zones split the open notch down the middle, so the cursor's side picks the target.
struct FileDropDelegate: DropDelegate {
    let model: NotchModel

    func validateDrop(info: DropInfo) -> Bool {
        model.dropping && info.hasItemsConforming(to: DroppedItem.types)
            && !info.hasItemsConforming(to: [.notchdWidget])
    }

    func dropEntered(info: DropInfo) { track(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: track(info) == nil ? .forbidden : .copy)
    }
    func dropExited(info: DropInfo) { setTarget(nil) }

    func performDrop(info: DropInfo) -> Bool {
        guard let target = track(info) else { return false }
        setTarget(nil)
        DroppedItem.load(info.itemProviders(for: DroppedItem.types)) { items in
            switch target {
            case .tray: TrayStore.shared.add(items)
            case .airDrop: AirDrop.send(items.map(\.shareable))
            }
        }
        Haptics.tap()
        return true
    }

    /// `location` is in the root view's space, which fills the panel; the open notch hangs from its top centre.
    @discardableResult
    private func track(_ info: DropInfo) -> NotchModel.DropTarget? {
        let target = target(at: info.location)
        setTarget(target)
        return target
    }

    private func target(at point: CGPoint) -> NotchModel.DropTarget? {
        guard model.dropping, model.isOpen else { return nil }
        let size = model.openSize
        let mid = model.screenWidth / 2
        guard point.y <= size.height, abs(point.x - mid) <= size.width / 2 else { return nil }
        return point.x < mid ? .tray : .airDrop
    }

    private func setTarget(_ target: NotchModel.DropTarget?) {
        guard model.dropTarget != target else { return }
        if target != nil { Haptics.tap() }
        model.dropTarget = target
    }
}

enum AirDrop {
    /// Opens the system AirDrop window for files, links, text or images.
    /// It also handles AirDrop being off, offering to turn it on.
    static func send(_ items: [Any]) {
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        // Notchd is a background app: without activating, the AirDrop window opens behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: items)
    }
}

private struct DropZone: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .symbolEffect(.bounce, value: targeted)
            VStack(spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).opacity(0.7)
            }
        }
        .foregroundStyle(targeted ? .white : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(targeted ? 0.14 : 0.05))
                .strokeBorder(.white.opacity(targeted ? 0.45 : 0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .scaleEffect(targeted ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: targeted)
    }
}
