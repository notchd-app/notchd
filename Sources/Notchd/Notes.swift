import AppKit
import SwiftUI

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Rich notes are RTF; code notes are plain text.
    var rtf = Data()
    var text = ""
    var code = false
    var updated = Date()

    /// First line, for the note list. Remembered per edit: working it out means decoding the whole
    /// note, and the list asks for it several times on every keystroke.
    var title: String {
        if let cached = Self.titles[id], cached.updated == updated, cached.code == code { return cached.title }
        let plain = code ? text : (NSAttributedString(rtf: rtf, documentAttributes: nil)?.string ?? "")
        let title = plain.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        Self.titles[id] = (updated, code, title)
        return title
    }

    private static var titles: [UUID: (updated: Date, code: Bool, title: String)] = [:]
}

@Observable
final class NotesStore {
    static let shared = NotesStore()
    private let file: URL
    private var saveWork: DispatchWorkItem?

    private(set) var notes: [Note] = []
    var selectedID: UUID?

    var selected: Note? { notes.first { $0.id == selectedID } ?? notes.first }

    init(file: URL = URL.appSupport.appendingPathComponent("notes.json")) {
        self.file = file
        notes = Stored.load([Note].self, from: file) ?? []
        if notes.isEmpty { notes = [Note()] }
        selectedID = notes.first?.id
    }

    func add() {
        // Reuse an empty note instead of piling them up.
        if let empty = notes.first(where: { $0.title.isEmpty }) {
            selectedID = empty.id
            return
        }
        let note = Note()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            notes.insert(note, at: 0)
            selectedID = note.id
        }
        save()
    }

    func delete(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            notes.removeAll { $0.id == id }
            if notes.isEmpty { notes = [Note()] }
            if selectedID == id { selectedID = notes.first?.id }
        }
        save()
    }

    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updated = Date()
        scheduleSave()
    }

    /// Switches a note between rich text and code, keeping its words.
    func toggleCode(_ id: UUID) {
        update(id) { note in
            if note.code {
                note.rtf = Self.rtf(NSAttributedString(string: note.text, attributes: NoteTextView.richAttributes))
            } else {
                note.text = NSAttributedString(rtf: note.rtf, documentAttributes: nil)?.string ?? ""
            }
            note.code.toggle()
        }
    }

    static func rtf(_ string: NSAttributedString) -> Data {
        (try? string.data(from: NSRange(location: 0, length: string.length),
                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    }

    /// Typing saves after a short pause rather than on every keystroke.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func save() {
        try? JSONEncoder().encode(notes).write(to: file, options: .atomic)
    }
}

// MARK: - Widget

struct NotesWidget: View {
    @Bindable var model: NotchModel
    @Bindable private var store = NotesStore.shared

    init(model: NotchModel) { self.model = model }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let note = store.selected {
                NoteEditor(note: note, onFocus: { model.typing = $0 })
                    .overlay(alignment: .topLeading) {
                        if note.title.isEmpty {
                            Text("Write something…")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .id(note.id)
                    .transition(.blurPop)
                    .overlay(alignment: .bottomTrailing) { NoteToolbar(note: note) }
            }
            noteList
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: store.selectedID)
    }

    private var noteList: some View {
        VStack(spacing: 4) {
            Button(action: store.add) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 22)
                    .background(Pill().fill(.white.opacity(0.08)))
            }
            .buttonStyle(BouncyButtonStyle())
            .help(Text("New note"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(store.notes) { note in
                        let selected = note.id == store.selected?.id
                        Button { store.selectedID = note.id } label: {
                            Text(note.title.isEmpty ? "·" : String(note.title.prefix(2)))
                                .font(.system(size: 11, weight: .semibold, design: note.code ? .monospaced : .rounded))
                                .foregroundStyle(selected ? .white : .secondary)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.white.opacity(selected ? 0.2 : 0.06)))
                        }
                        .buttonStyle(BouncyButtonStyle())
                        .help(note.title.isEmpty ? Text("Empty note") : Text(note.title))
                        .contextMenu {
                            Button("Delete Note", role: .destructive) { store.delete(note.id) }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .frame(width: 26)
    }
}

/// Bold / italic / underline and the code switch, floating over the editor.
private struct NoteToolbar: View {
    let note: Note
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            if !note.code {
                button("bold", action: "toggleBold:", help: "Bold (⌘B)")
                button("italic", action: "toggleItalic:", help: "Italic (⌘I)")
                button("underline", action: "underline:", help: "Underline (⌘U)")
            }
            Button { NotesStore.shared.toggleCode(note.id) } label: {
                Image(systemName: "curlybraces")
                    .foregroundStyle(note.code ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 18)
            }
            .help(note.code ? Text("Back to rich text") : Text("Code: monospaced, with colors"))
        }
        .font(.system(size: 10, weight: .bold))
        .buttonStyle(BouncyButtonStyle())
        .padding(.horizontal, 3)
        .background(Pill().fill(.black.opacity(0.6)))
        .background(Pill().fill(.white.opacity(0.08)))
        .opacity(hovering ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func button(_ icon: String, action: String, help: LocalizedStringKey) -> some View {
        Button {
            // The click may have taken focus from the text: act on the last editor and give focus back.
            guard let text = NoteTextView.last else { return }
            text.window?.makeFirstResponder(text)
            text.perform(Selector(action), with: nil)
        } label: {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20, height: 18)
        }
        .help(Text(help))
    }
}

// MARK: - Editor

struct NoteEditor: NSViewRepresentable {
    let note: Note
    let onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let text = NoteTextView()
        text.delegate = context.coordinator
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.insertionPointColor = .white
        scroll.documentView = text
        load(note, into: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NoteTextView else { return }
        context.coordinator.noteID = note.id
        text.onFocus = onFocus
        // Only reload when switching mode; while typing, the text view is the source of truth.
        if text.code != note.code { load(note, into: text) }
    }

    private func load(_ note: Note, into text: NoteTextView) {
        text.code = note.code
        text.isRichText = !note.code
        if note.code {
            text.string = note.text
            text.typingAttributes = NoteTextView.codeAttributes
            text.highlight()
        } else {
            let content = NSAttributedString(rtf: note.rtf, documentAttributes: nil) ?? NSAttributedString()
            text.textStorage?.setAttributedString(content)
            text.typingAttributes = NoteTextView.richAttributes
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID?

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NoteTextView, let noteID else { return }
            if text.code {
                // Coloring rescans the whole note: wait for a pause in typing.
                NSObject.cancelPreviousPerformRequests(withTarget: text, selector: #selector(NoteTextView.highlightNow), object: nil)
                text.perform(#selector(NoteTextView.highlightNow), with: nil, afterDelay: 0.15)
                NotesStore.shared.update(noteID) { $0.text = text.string }
            } else if let storage = text.textStorage {
                NotesStore.shared.update(noteID) { $0.rtf = NotesStore.rtf(storage) }
            }
        }
    }
}

final class NoteTextView: NSTextView {
    var code = false
    var onFocus: ((Bool) -> Void)?
    /// Most recently focused editor, for the toolbar buttons.
    static weak var last: NoteTextView?

    static let richAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
    ]
    static let codeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.white,
    ]

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            Self.last = self
            onFocus?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }

    /// Escape leaves the note, like clicking elsewhere.
    override func cancelOperation(_ sender: Any?) { window?.makeFirstResponder(nil) }

    /// Pasted styles (black text from a web page...) would be unreadable on the black notch.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    @objc func toggleBold(_ sender: Any?) { toggle(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggle(.italicFontMask) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(underline(_:))].contains(item.action) {
            return !code
        }
        return super.validateUserInterfaceItem(item)
    }

    private func toggle(_ trait: NSFontTraitMask) {
        guard !code, let storage = textStorage else { return }
        let manager = NSFontManager.shared
        let range = selectedRange()
        let current = (range.length > 0 ? storage.attribute(.font, at: range.location, effectiveRange: nil)
            : typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: 13)
        let has = manager.traits(of: current).contains(trait)
        let convert = { (font: NSFont) in
            has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: convert(value as? NSFont ?? current), range: sub)
            }
            storage.endEditing()
            didChangeText()
        }
        typingAttributes[.font] = convert(current)
    }

    /// Light syntax coloring that suits most languages: comments, strings, numbers and common keywords.
    @objc func highlightNow() { highlight() }

    func highlight() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(Self.codeAttributes, range: all)
        // Very long notes stay plain: the patterns would take seconds on them.
        if Settings.shared.prefs.notesHighlightCode, storage.length <= 200_000 {
            for (regex, color) in Self.rules {
                regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                    if let match { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                }
            }
        }
        storage.endEditing()
    }

    // Later rules win: strings and comments are colored last so keywords inside them don't show.
    private static let rules: [(NSRegularExpression, NSColor)] = [
        (#"\b(let|var|const|func|function|fn|def|class|struct|enum|interface|type|import|from|package|return|if|else|elif|for|while|do|switch|case|break|continue|in|of|try|catch|throw|throws|async|await|public|private|static|self|this|new|nil|null|None|true|false|True|False|guard|where|extension|protocol|include|define|echo|then|fi|done|select|insert|update|delete|create|table)\b"#,
         NSColor.systemPink),
        (#"\b\d+(\.\d+)?\b"#, NSColor.systemOrange),
        (#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`[^`]*`"#, NSColor.systemGreen),
        (#"(//|#)[^\n]*|/\*[\s\S]*?\*/"#, NSColor.systemGray),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
