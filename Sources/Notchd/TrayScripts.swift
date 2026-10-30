import Foundation

/// Your own tray actions: any executable file in Application Support/Notchd/Scripts shows up in a tray file's
/// right-click menu (Run Script) and as a tray rule step. The contract is in the example script below.
enum TrayScripts {
    static let folder = URL.appSupport.appendingPathComponent("Scripts", isDirectory: true)
    static let timeout: TimeInterval = 60

    static let example = """
    #!/bin/sh
    # A Notchd tray script. Every executable file in this folder can be run on tray
    # files from their right-click menu (Run Script) or from a tray rule.
    #
    #   "$@"            the tray files, as full paths
    #   $NOTCHD_OUTPUT  an empty folder: whatever you write there lands in the tray
    #
    # It runs in the files' folder and is stopped after 60 seconds. Exit with a
    # non-zero code to report a problem; what you print to stderr is shown.
    # Originals change only if your script changes them.
    # New script: copy this file, then `chmod +x` it.

    # This one writes a list of the files with their sizes.
    for f in "$@"; do
      printf '%s\\t%s\\n' "$(du -sh "$f" | cut -f1)" "$(basename "$f")"
    done > "$NOTCHD_OUTPUT/File list.txt"

    """

    /// The scripts you can run, by name. The folder and its example appear the first time it's looked at.
    static func list(in folder: URL = folder) -> [String] {
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("File List.sh")
            if (try? example.write(to: file, atomically: true, encoding: .utf8)) != nil {
                try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        return ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { url(named: $0, in: folder) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Only plain executable files directly in the folder: a name from the prefs can't reach anywhere else.
    static func url(named name: String, in folder: URL = folder) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let url = folder.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Runs the script on `files` and returns what it wrote to $NOTCHD_OUTPUT. Paths go in as separate
    /// arguments, never through a shell, so no file name can turn into a command.
    static func run(_ name: String, on files: [URL], in scratch: URL, folder: URL = folder,
                    timeout: TimeInterval = timeout) throws -> [URL] {
        guard let script = url(named: name, in: folder) else {
            throw TrayActions.ActionError(String(localized: "The script “\(name)” isn't in the Scripts folder or isn't executable."))
        }
        let output = scratch.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = script
        process.arguments = files.map(\.path)
        process.currentDirectoryURL = files.first?.deletingLastPathComponent() ?? scratch
        var environment = ProcessInfo.processInfo.environment
        environment["NOTCHD_OUTPUT"] = output.path
        // Apps opened from the Finder get a bare PATH: add Homebrew's so scripts find the tools they use in Terminal.
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            throw TrayActions.ActionError(String(localized: "“\(name)” couldn't start. Does it begin with a line like #!/bin/sh?"))
        }
        // Read on the side: a script that fills the pipe would otherwise never finish.
        var message = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            message = errors.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TrayActions.ActionError(String(localized: "“\(name)” took longer than \(Int(timeout)) seconds and was stopped."))
        }
        // A background child may still hold stderr open: then there's no message to show.
        let read = reading.wait(timeout: .now() + 1) == .success
        guard process.terminationStatus == 0 else {
            let text = read ? String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            throw TrayActions.ActionError(text.isEmpty ? String(localized: "“\(name)” failed (exit code \(process.terminationStatus)).") : text)
        }
        return try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
