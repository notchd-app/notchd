import Foundation
import UniformTypeIdentifiers

/// Automatic actions for files arriving in the tray: "when a zip lands, expand it". The first enabled
/// rule that matches a file wins; its steps run in order, each one working on what the previous made.
/// Results land in the tray like the right-click actions' results, and never trigger rules themselves.
struct TrayRule: Codable, Equatable, Identifiable {
    enum FileKind: String, Codable, CaseIterable, Identifiable {
        case any, image, pdf, archive, movie, text
        var id: Self { self }
        var title: String {
            L(["any": "Any file", "image": "Image", "pdf": "PDF", "archive": "Archive", "movie": "Video",
               "text": "Text"][rawValue]!)
        }

        func matches(_ type: UTType?) -> Bool {
            guard self != .any else { return true }
            guard let type else { return false }
            switch self {
            case .any: return true
            case .image: return type.conforms(to: .image)
            case .pdf: return type.conforms(to: .pdf)
            case .archive: return type.conforms(to: .archive) || type.conforms(to: .zip)
            case .movie: return type.conforms(to: .movie)
            case .text: return type.conforms(to: .text)
            }
        }
    }

    enum Step: Codable, Equatable {
        case expand, compress, convert(TrayActions.ImageFormat), shrink, removeBackground, makePDF
        /// Copies the files into a folder; nothing more goes to the tray.
        case saveTo(String)
        /// One of your scripts (TrayScripts.swift), by file name; what it writes to $NOTCHD_OUTPUT goes on.
        case script(String)

        /// One of each, for the "Add Step" menu.
        static let all: [Step] = [.expand, .compress, .convert(.jpeg), .shrink, .removeBackground, .makePDF,
                                  .script(""), .saveTo("")]
        var title: String {
            switch self {
            case .expand: L("Expand archives")
            case .compress: L("Compress into a zip")
            case .convert: L("Convert images")
            case .shrink: L("Make images smaller")
            case .removeBackground: L("Remove background")
            case .makePDF: L("Make a PDF of the images")
            case .script: L("Run a script")
            case .saveTo: L("Save to a folder")
            }
        }
        var icon: String {
            switch self {
            case .expand: "arrow.up.bin"
            case .compress: "archivebox"
            case .convert: "photo.on.rectangle"
            case .shrink: "arrow.down.right.and.arrow.up.left"
            case .removeBackground: "person.crop.rectangle"
            case .makePDF: "doc.richtext"
            case .script: "terminal"
            case .saveTo: "folder"
            }
        }
    }

    var id = UUID()
    var name = ""
    var enabled = true
    // Conditions: all of them must hold. Empty means "any".
    var kind = FileKind.any
    var extensions: [String] = []  // without the dot, any case
    var namePattern = ""  // shell wildcards, any case: "Screenshot*"
    var minBytes: Int?
    var maxBytes: Int?
    var steps: [Step] = []
    var trashOriginal = false

    var title: String { name.isEmpty ? L("Untitled Rule") : name }

    func matches(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard kind.matches(values?.contentType) else { return false }
        if !extensions.isEmpty, !extensions.contains(where: { $0.lowercased() == url.pathExtension.lowercased() }) { return false }
        if !namePattern.isEmpty, fnmatch(namePattern, url.lastPathComponent, FNM_CASEFOLD) != 0 { return false }
        if minBytes != nil || maxBytes != nil {
            // Folders have no size: a size condition never matches them.
            guard let size = values?.fileSize else { return false }
            if let minBytes, size < minBytes { return false }
            if let maxBytes, size > maxBytes { return false }
        }
        return true
    }
}

enum TrayRules {
    /// Runs the matching rules on files that just arrived. Files caught by the same rule go through it together,
    /// so "Compress" makes one archive of a whole drop.
    static func process(_ urls: [URL], rules: [TrayRule], actions: TrayActions = .shared, store: TrayStore = .shared) {
        for (rule, files) in matches(urls, rules: rules) {
            // A rule runs on its own, so a modal alert would come out of nowhere: the tray shows a banner instead.
            actions.run({ scratch in try run(rule.steps, on: files, in: scratch) }, into: store,
                        report: { store.ruleError = "\(rule.title): \($0)" }) {
                if rule.trashOriginal { store.remove(files) }
            }
        }
    }

    /// Each file goes to the first enabled rule that has steps and matches it.
    static func matches(_ urls: [URL], rules: [TrayRule]) -> [(TrayRule, [URL])] {
        var result: [(TrayRule, [URL])] = []
        for url in urls {
            guard let rule = rules.first(where: { $0.enabled && !$0.steps.isEmpty && $0.matches(url) }) else { continue }
            if let i = result.firstIndex(where: { $0.0.id == rule.id }) { result[i].1.append(url) } else { result.append((rule, [url])) }
        }
        return result
    }

    /// The pipeline: each step works on the files the step before produced. Files a step doesn't apply to
    /// (a PDF reaching "Convert image") pass through unchanged. Each step gets its own folder, so names never clash.
    /// ponytail: steps see only top-level files; an expanded folder isn't searched for images. Recurse if rules need it.
    static func run(_ steps: [TrayRule.Step], on urls: [URL], in scratch: URL) throws -> [URL] {
        var files = urls
        for (index, step) in steps.enumerated() {
            let folder = scratch.appendingPathComponent("step-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            files = try apply(step, to: files, in: folder)
        }
        return files
    }

    private static func apply(_ step: TrayRule.Step, to files: [URL], in folder: URL) throws -> [URL] {
        let images = files.filter(TrayActions.isImage)
        let others = files.filter { !TrayActions.isImage($0) }
        switch step {
        case .expand:
            return try files.flatMap { TrayActions.isZip($0) ? try TrayActions.expand($0, in: folder) : [$0] }
        case .compress:
            return files.isEmpty ? [] : try TrayActions.compress(files, in: folder)
        case let .convert(format):
            return try (images.isEmpty ? [] : TrayActions.convert(images, to: format, in: folder)) + others
        case .shrink:
            return try (images.isEmpty ? [] : TrayActions.shrink(images, in: folder)) + others
        case .removeBackground:
            return try (images.isEmpty ? [] : TrayActions.removeBackground(images, in: folder)) + others
        case .makePDF:
            return try (images.isEmpty ? [] : TrayActions.makePDF(images, in: folder)) + others
        case let .script(name):
            return try TrayScripts.run(name, on: files, in: folder)
        case let .saveTo(path):
            let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files {
                let ext = file.pathExtension
                let target = TrayActions.unique(destination, ext.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent, ext)
                try FileManager.default.copyItem(at: file, to: target)
            }
            return []
        }
    }
}
