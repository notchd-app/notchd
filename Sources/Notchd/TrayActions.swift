import AppKit
import CoreImage
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Things you can do to tray files from their right-click menu. Results land in the tray next to the
/// originals; originals are never changed.
@Observable
final class TrayActions {
    static let shared = TrayActions()
    /// Jobs still running, for the spinner in the tray's corner.
    private(set) var working = 0

    enum ImageFormat: String, CaseIterable, Codable {
        case png, jpeg, heic

        var type: UTType { self == .png ? .png : self == .jpeg ? .jpeg : .heic }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var title: String { self == .png ? "PNG" : self == .jpeg ? "JPEG" : "HEIC" }
    }

    static func isImage(_ url: URL) -> Bool { contentType(url)?.conforms(to: .image) == true }
    static func isZip(_ url: URL) -> Bool { contentType(url)?.conforms(to: .zip) == true }
    static func isPDF(_ url: URL) -> Bool { contentType(url)?.conforms(to: .pdf) == true }

    private static func contentType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }

    // MARK: Menu

    /// Adds the actions that apply to `urls` to a tray item's menu.
    func addItems(to menu: ClosureMenu, for urls: [URL]) {
        guard !urls.isEmpty else { return }
        menu.addItem(.separator())
        let images = urls.filter(Self.isImage)
        menu.add(urls.count == 1 ? String(localized: "Compress “\(urls[0].lastPathComponent)”")
                                 : String(localized: "Compress \(urls.count) Items")) { [self] in compress(urls) }
        if urls.count == 1, Self.isZip(urls[0]) {
            menu.add(String(localized: "Expand")) { [self] in expand(urls[0]) }
        }
        if !images.isEmpty, images.count == urls.count {
            let convert = ClosureMenu()
            for format in ImageFormat.allCases {
                convert.add(format.title) { [self] in self.convert(images, to: format) }
            }
            let item = NSMenuItem(title: String(localized: "Convert Image To"), action: nil, keyEquivalent: "")
            item.submenu = convert
            menu.addItem(item)
            menu.add(String(localized: "Make Smaller")) { [self] in shrink(images) }
            menu.add(String(localized: "Remove Background")) { [self] in removeBackground(images) }
            menu.add(images.count == 1 ? String(localized: "Make PDF") : String(localized: "Combine into PDF")) { [self] in
                makePDF(images)
            }
            menu.add(String(localized: "Copy Text in Image")) { [self] in copyText(images) }
        }
        if urls.count > 1, urls.allSatisfy(Self.isPDF) {
            menu.add(String(localized: "Combine PDFs")) { [self] in combinePDFs(urls) }
        }
        let scripts = ClosureMenu()
        for name in TrayScripts.list() {
            scripts.add(name) { [self] in run { try TrayScripts.run(name, on: urls, in: $0) } }
        }
        if !scripts.items.isEmpty { scripts.addItem(.separator()) }
        scripts.add(String(localized: "Open Scripts Folder")) { NSWorkspace.shared.open(TrayScripts.folder) }
        let item = NSMenuItem(title: String(localized: "Run Script"), action: nil, keyEquivalent: "")
        item.submenu = scripts
        menu.addItem(item)
    }

    // MARK: Actions

    func compress(_ urls: [URL]) { run { try Self.compress(urls, in: $0) } }
    func expand(_ url: URL) { run { try Self.expand(url, in: $0) } }
    func convert(_ urls: [URL], to format: ImageFormat) { run { try Self.convert(urls, to: format, in: $0) } }
    func shrink(_ urls: [URL]) { run { try Self.shrink(urls, in: $0) } }
    func removeBackground(_ urls: [URL]) { run { try Self.removeBackground(urls, in: $0) } }
    func makePDF(_ urls: [URL]) { run { try Self.makePDF(urls, in: $0) } }
    func combinePDFs(_ urls: [URL]) { run { try Self.combinePDFs(urls, in: $0) } }

    // MARK: Jobs
    // Each one reads `urls`, writes its results into `scratch` and returns them. The menu and the tray
    // rules (TrayRules.swift) share them.

    static func compress(_ urls: [URL], in scratch: URL) throws -> [URL] {
        let name = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "Archive")
        let output = unique(scratch, name, "zip")
        // zip from inside the folder keeps paths short (no /Users/... inside the archive).
        let parent = urls[0].deletingLastPathComponent()
        try tool("/usr/bin/zip", ["-r", "-y", "-q", output.path] + urls.map(\.lastPathComponent), in: parent)
        return [output]
    }

    static func expand(_ url: URL, in scratch: URL) throws -> [URL] {
        let folder = scratch.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try tool("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
        // An archive of one folder expands to that folder, not a folder inside a folder.
        let inside = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        return inside.count == 1 ? inside : [folder]
    }

    static func convert(_ urls: [URL], to format: ImageFormat, in scratch: URL) throws -> [URL] {
        try urls.map { url in
            let output = unique(scratch, url.deletingPathExtension().lastPathComponent, format.fileExtension)
            try writeImage(from: url, to: output, type: format.type, quality: 0.9, maxPixels: nil)
            return output
        }
    }

    /// JPEG at 75% quality, at most 2560 pixels on the long side: good for mail and chat.
    static func shrink(_ urls: [URL], in scratch: URL) throws -> [URL] {
        try urls.map { url in
            let output = unique(scratch, String(localized: "\(url.deletingPathExtension().lastPathComponent) (smaller)"), "jpg")
            try writeImage(from: url, to: output, type: .jpeg, quality: 0.75, maxPixels: 2560)
            return output
        }
    }

    /// Lifts the subject out of the photo, like Preview's Remove Background, into a transparent PNG.
    static func removeBackground(_ urls: [URL], in scratch: URL) throws -> [URL] {
        try urls.map { url in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            guard let result = request.results?.first else { throw ActionError(L("No subject found in the image.")) }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
            let image = CIImage(cvPixelBuffer: buffer)
            let output = unique(scratch, String(localized: "\(url.deletingPathExtension().lastPathComponent) (no background)"), "png")
            let context = CIContext()
            try context.writePNGRepresentation(of: image, to: output, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return output
        }
    }

    static func makePDF(_ urls: [URL], in scratch: URL) throws -> [URL] {
        let document = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { throw ActionError(L("These images couldn't be read.")) }
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : L("Images")
        let output = unique(scratch, name, "pdf")
        guard document.write(to: output) else { throw ActionError(L("The PDF couldn't be saved.")) }
        return [output]
    }

    static func combinePDFs(_ urls: [URL], in scratch: URL) throws -> [URL] {
        let combined = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { continue }
            for i in 0..<document.pageCount {
                if let page = document.page(at: i) { combined.insert(page, at: combined.pageCount) }
            }
        }
        let output = unique(scratch, L("Combined"), "pdf")
        guard combined.pageCount > 0, combined.write(to: output) else { throw ActionError(L("The PDF couldn't be saved.")) }
        return [output]
    }

    /// Reads the text in images (Live Text) and puts it on the clipboard.
    func copyText(_ urls: [URL]) {
        working += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let text = urls.map { url -> String in
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try? VNImageRequestHandler(url: url).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            DispatchQueue.main.async {
                self.working -= 1
                guard !text.isEmpty else { return Self.alert(L("No text found in the image.")) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Haptics.tap()
            }
        }
    }

    // MARK: Plumbing

    struct ActionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Runs `job` off the main thread in a scratch folder, then moves what it made into the tray and calls `done`.
    /// Problems go to `report`: an alert for what you clicked, the tray's banner for rules.
    func run(_ job: @escaping (URL) throws -> [URL], into store: TrayStore = .shared,
             report: @escaping (String) -> Void = TrayActions.alert, then done: @escaping () -> Void = {}) {
        working += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-action-\(UUID().uuidString)")
            let result = Result { () -> [URL] in
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                return try job(scratch)
            }
            DispatchQueue.main.async {
                self.working -= 1
                switch result {
                case let .success(outputs):
                    var imported = true
                    for output in outputs {
                        do { try store.importCapture(from: output) } catch {
                            imported = false
                            report(error.localizedDescription)
                        }
                    }
                    Haptics.tap()
                    // `done` may trash the originals: only once every result is safely in the tray.
                    if imported { done() }
                case let .failure(error):
                    report(error.localizedDescription)
                }
                try? FileManager.default.removeItem(at: scratch)
            }
        }
    }

    static func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("That didn't work")
        alert.informativeText = message
        alert.runModal()
    }

    /// "a.png", then "a 2.png"…: two sources with the same name mustn't overwrite each other's result.
    static func unique(_ folder: URL, _ name: String, _ ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func tool(_ path: String, _ args: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // Read before waiting: a full pipe would otherwise block the tool forever.
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self)
            throw ActionError(message.isEmpty ? "\((path as NSString).lastPathComponent) failed." : message)
        }
    }

    /// Re-encodes an image with ImageIO, keeping its orientation and color profile.
    static func writeImage(from url: URL, to output: URL, type: UTType, quality: Double, maxPixels: Int?) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ActionError(L("These images couldn't be read.")) }
        let image: CGImage?
        if let maxPixels {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
        else { throw ActionError(L("These images couldn't be read.")) }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        if maxPixels != nil { properties[kCGImagePropertyOrientation] = 1 }  // the thumbnail is already upright
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ActionError(L("The image couldn't be saved.")) }
    }
}
