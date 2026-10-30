import AppKit
@testable import Notchd
import Testing

private func temporary(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePNG(_ url: URL) throws {
    let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
        NSColor.systemPink.setFill(); rect.fill(); return true
    }
    try #require(image.pngData).write(to: url)
}

@Test func trayRulesMatchConditions() throws {
    let folder = try temporary("rules-match")
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = folder.appendingPathComponent("Screenshot 2026.png")
    try writePNG(png)
    let text = folder.appendingPathComponent("notes.TXT")
    try Data("hello".utf8).write(to: text)

    #expect(TrayRule(kind: .image).matches(png))
    #expect(!TrayRule(kind: .image).matches(text))
    #expect(TrayRule(extensions: ["txt"]).matches(text))  // any case
    #expect(TrayRule(namePattern: "screenshot*").matches(png))
    #expect(!TrayRule(namePattern: "screenshot*").matches(text))
    #expect(TrayRule(maxBytes: 10).matches(text))
    #expect(!TrayRule(minBytes: 10).matches(text))
    #expect(!TrayRule(minBytes: 1).matches(folder))  // folders have no size

    // First enabled rule with steps wins; files caught by one rule are grouped.
    let off = TrayRule(name: "off", enabled: false, steps: [.compress])
    let empty = TrayRule(name: "empty", kind: .image)
    let images = TrayRule(name: "images", kind: .image, steps: [.shrink])
    let rest = TrayRule(name: "rest", steps: [.compress])
    let groups = TrayRules.matches([png, text], rules: [off, empty, images, rest])
    #expect(groups.map(\.0.name) == ["images", "rest"])
    #expect(groups.map(\.1) == [[png], [text]])
    #expect(TrayRules.matches([png, text], rules: [rest]).first?.1 == [png, text])
}

@Test func trayRulePipelineChainsSteps() throws {
    let folder = try temporary("rules-pipeline")
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = folder.appendingPathComponent("photo.png")
    try writePNG(png)
    let archive = folder.appendingPathComponent("photo.zip")
    try TrayActions.tool("/usr/bin/zip", ["-q", archive.path, "photo.png"], in: folder)
    let pdf = folder.appendingPathComponent("doc.pdf")
    try Data("%PDF-1.4".utf8).write(to: pdf)

    // Expand, then convert what came out; the PDF isn't an image and passes through untouched.
    let scratch = try temporary("rules-scratch")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let out = try TrayRules.run([.expand, .convert(.jpeg)], on: [archive, pdf], in: scratch)
    #expect(out.map(\.lastPathComponent) == ["photo.jpg", "doc.pdf"])
    #expect(TrayActions.isImage(out[0]))

    // Save to a folder copies everything there and sends nothing on to the tray.
    let destination = folder.appendingPathComponent("saved")
    #expect(try TrayRules.run([.saveTo(destination.path)], on: [png, png], in: scratch).isEmpty)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) == ["photo.png", "photo 2.png"])
    #expect(FileManager.default.fileExists(atPath: png.path))
}

@Test func trayRulesStoreAndDecode() throws {
    let preferences = TestPreferences()
    preferences.settings.prefs.trayRules = [TrayRule(name: "Zips", kind: .archive, steps: [.expand, .convert(.heic), .saveTo("~/x")],
                                                     trashOriginal: true)]
    #expect(Settings(defaults: preferences.defaults).prefs.trayRules == preferences.settings.prefs.trayRules)
}

/// A rule's results come back through `importCapture`: a catch-all rule must run once, not on its own output.
@MainActor @Test func trayRuleRunsOnDropsButNotOnItsOwnResults() async throws {
    let dir = try temporary("rules-tray")
    let source = try temporary("rules-src")
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: source)
    }
    let preferences = TestPreferences()
    preferences.settings.prefs.trayRules = [TrayRule(steps: [.compress], trashOriginal: true)]
    let store = TrayStore(folder: dir, settings: preferences.settings)
    let file = source.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: file)

    store.add([file])
    for _ in 0..<50 where store.files.map(\.lastPathComponent) != ["a.txt.zip"] {
        try await Task.sleep(for: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(300))  // room for a runaway second round to show up
    #expect(store.files.map(\.lastPathComponent) == ["a.txt.zip"])
    #expect(FileManager.default.fileExists(atPath: file.path))  // only the tray copy is trashed
}

// MARK: - Scripts

private func script(_ name: String, in folder: URL, _ body: String, executable: Bool = true) throws {
    let url = folder.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
}

@Test func trayScriptsFolderListsOnlyRunnableScripts() throws {
    let parent = try temporary("scripts-list")
    defer { try? FileManager.default.removeItem(at: parent) }
    let folder = parent.appendingPathComponent("Scripts")

    // First look creates the folder with a working example.
    #expect(TrayScripts.list(in: folder) == ["File List.sh"])
    try script("b.sh", in: folder, "true")
    try script("not executable.sh", in: folder, "true", executable: false)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir"), withIntermediateDirectories: true)
    #expect(TrayScripts.list(in: folder) == ["b.sh", "File List.sh"])
    for name in ["", "../b.sh", "dir", ".hidden", "missing.sh"] { #expect(TrayScripts.url(named: name, in: folder) == nil) }

    let file = parent.appendingPathComponent("a.txt")
    try Data("abc".utf8).write(to: file)
    let scratch = try temporary("scripts-example")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let out = try TrayScripts.run("File List.sh", on: [file], in: scratch, folder: folder)
    #expect(out.map(\.lastPathComponent) == ["File list.txt"])
    #expect(try String(contentsOf: out[0], encoding: .utf8).contains("a.txt"))
}

@Test func trayScriptsContract() throws {
    let folder = try temporary("scripts-run")
    defer { try? FileManager.default.removeItem(at: folder) }
    let scratch = try temporary("scripts-scratch")
    defer { try? FileManager.default.removeItem(at: scratch) }
    // A file name that would run a command if it ever went through a shell.
    let tricky = folder.appendingPathComponent("a; touch pwned.txt")
    try Data("x".utf8).write(to: tricky)

    // Arguments arrive as-is, the working folder is the files' folder, $NOTCHD_OUTPUT collects the results.
    try script("echo.sh", in: folder, #"for f in "$@"; do basename "$f"; done > "$NOTCHD_OUTPUT/args.txt"; pwd -P > "$NOTCHD_OUTPUT/pwd.txt""#)
    let out = try TrayScripts.run("echo.sh", on: [tricky], in: scratch, folder: folder)
    #expect(out.map(\.lastPathComponent) == ["args.txt", "pwd.txt"])
    #expect(try String(contentsOf: out[0], encoding: .utf8) == "a; touch pwned.txt\n")
    #expect(try String(contentsOf: out[1], encoding: .utf8).hasSuffix("/" + folder.lastPathComponent + "\n"))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pwned.txt").path))

    // Failures report stderr, or the exit code when there's nothing to say.
    try script("fail.sh", in: folder, "echo 'no such tool' >&2; exit 3")
    #expect { try TrayScripts.run("fail.sh", on: [], in: scratch, folder: folder) } throws: {
        ($0 as? TrayActions.ActionError)?.errorDescription == "no such tool"
    }
    try script("quiet.sh", in: folder, "exit 2")
    #expect { try TrayScripts.run("quiet.sh", on: [], in: scratch, folder: folder) } throws: {
        ($0 as? TrayActions.ActionError)?.errorDescription?.contains("2") == true
    }
    // A script that hangs is stopped.
    try script("slow.sh", in: folder, "sleep 30")
    let start = Date()
    #expect(throws: TrayActions.ActionError.self) { try TrayScripts.run("slow.sh", on: [], in: scratch, folder: folder, timeout: 0.5) }
    #expect(Date().timeIntervalSince(start) < 5)
    // No shebang: a clear error, not a crash.
    try "echo hi\n".write(to: folder.appendingPathComponent("bare"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("bare").path)
    #expect(throws: TrayActions.ActionError.self) { try TrayScripts.run("bare", on: [], in: scratch, folder: folder) }
}
