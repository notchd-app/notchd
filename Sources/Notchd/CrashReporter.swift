import AppKit
import Darwin

// MARK: - Signal handler (must stay async-signal-safe: no allocation, no Swift runtime calls that lock)

private var crashFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private let crashFrameCount: Int32 = 96

private func crashWrite(_ text: StaticString) {
    text.withUTF8Buffer { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
}

private func crashSignalHandler(_ signal: Int32) {
    crashWrite("\n*** Notchd crashed: ")
    switch signal {
    case SIGABRT: crashWrite("SIGABRT (the app stopped itself: failed check, uncaught exception)")
    case SIGSEGV: crashWrite("SIGSEGV (bad memory access)")
    case SIGBUS: crashWrite("SIGBUS (bad memory access)")
    case SIGILL: crashWrite("SIGILL (illegal instruction)")
    case SIGTRAP: crashWrite("SIGTRAP (Swift runtime error: see the \"Fatal error\" line above, if any)")
    case SIGFPE: crashWrite("SIGFPE (arithmetic error)")
    default: crashWrite("signal")
    }
    crashWrite("\nBacktrace of the crashing thread:\n")
    if let crashFrames {
        let count = backtrace(crashFrames, crashFrameCount)
        backtrace_symbols_fd(crashFrames, count, STDERR_FILENO)
    }
    crashWrite("*** end of crash\n")
    // Hand over to the default action, so macOS still writes its own report.
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

// MARK: - Crash reporter

/// Keeps a log of each session on this Mac and, when the app didn't quit normally, saves a crash report
/// next to it at the following launch. Nothing is ever sent anywhere.
///
/// How: stderr (NSLog, Swift "Fatal error" messages, AppKit exception dumps) is redirected to
/// ~/Library/Logs/Notchd/notchd.log; fatal signals append a backtrace; a normal quit writes a last line.
/// A log without that last line means the previous session crashed, was force quit or lost power.
enum CrashReporter {
    static let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Notchd", isDirectory: true)
    static var reportsFolder: URL { folder.appendingPathComponent("Crash Reports", isDirectory: true) }
    static let logName = "notchd.log"
    static let cleanExitLine = "--- quit normally"
    static let crashMarker = "*** Notchd crashed"
    static let freezeMarker = "[Watchdog] the app is frozen"
    private static let maxReports = 25
    private static var watchdog: DispatchSourceTimer?

    /// Call first thing at launch.
    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
        let previousLaunch = collect(logs: folder, systemReports: systemReportsFolder)
        let log = folder.appendingPathComponent(logName)
        // Launched from a terminal (development): leave the output where the developer is looking.
        if isatty(STDERR_FILENO) == 0 {
            let fd = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
            if fd >= 0 {
                dup2(fd, STDERR_FILENO)
                close(fd)
            }
        }
        NSLog("%@", header())

        NSSetUncaughtExceptionHandler { exception in
            NSLog("*** Uncaught exception %@: %@\n%@", exception.name.rawValue, exception.reason ?? "",
                  exception.callStackSymbols.joined(separator: "\n"))
        }
        crashFrames = .allocate(capacity: Int(crashFrameCount))
        // Its own stack, so a stack overflow (runaway recursion) can still be reported.
        let stackSize = 256 * 1024
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16),
                            ss_size: stackSize, ss_flags: 0)
        sigaltstack(&stack, nil)
        for signal in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
        // A broken pipe (a helper that died) is an error to handle, not a reason to die.
        signal(SIGPIPE, SIG_IGN)

        startWatchdog()
        // macOS writes its own report a few seconds after a crash: pick it up if it wasn't there yet.
        if let previousLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                copySystemReports(since: previousLaunch, from: systemReportsFolder, to: reportsFolder)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in trimLog() }
    }

    /// Call when the app quits on purpose.
    static func markCleanExit() {
        NSLog("%@", cleanExitLine)
    }

    static var systemReportsFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    private static func header() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return """
        === notchd \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0")) \
        launched \(ISO8601DateFormatter().string(from: Date()))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(String(cString: model)), \
        \(NSScreen.screens.count) screen(s), \(Locale.current.identifier)
        app: \(Bundle.main.bundlePath)
        """
    }

    // MARK: Reports

    /// Looks at the log the previous session left in `logs`. If that session didn't quit normally, saves a
    /// report (the log, plus any macOS crash reports written since it launched) and returns its launch date.
    /// The old log is then kept as notchd-previous.log.
    @discardableResult
    static func collect(logs: URL, systemReports: URL, now: Date = Date()) -> Date? {
        let fm = FileManager.default
        let log = logs.appendingPathComponent(logName)
        guard let data = try? Data(contentsOf: log), !data.isEmpty else { return nil }
        let previous = logs.appendingPathComponent("notchd-previous.log")
        defer {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: log, to: previous)
        }
        let text = String(decoding: data.suffix(400_000), as: UTF8.self)
        let crashed = text.contains(crashMarker) || text.contains("Fatal error") || text.contains("*** Uncaught exception")
        let froze = text.contains(freezeMarker)
        // A session that quit normally is only worth a report if it froze along the way.
        guard !endedCleanly(text) || crashed || froze else { return nil }
        let launched = (try? log.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
        let reports = logs.appendingPathComponent("Crash Reports", isDirectory: true)
        try? fm.createDirectory(at: reports, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let kind = crashed ? "Notchd crash " : endedCleanly(text) ? "Notchd froze " : "Notchd stopped unexpectedly "
        let name = kind + stamp.string(from: now) + ".txt"
        let summary = crashed
            ? "Notchd crashed. The lines marked *** near the end say why; the backtrace shows where."
            : endedCleanly(text)
            ? "Notchd froze for a while during this session (see the [Watchdog] lines), then carried on."
            : "Notchd stopped without quitting normally and without recording a crash: it was force quit, "
              + "the Mac lost power or restarted, or the app was frozen (look for [Watchdog] lines)."
        let body = """
        \(summary)
        Session started \(ISO8601DateFormatter().string(from: launched)); report saved \(ISO8601DateFormatter().string(from: now)).
        macOS's own crash reports from that session, if any, are copied next to this file (.ips).

        ----- log of that session -----
        \(text)
        """
        try? Data(body.utf8).write(to: reports.appendingPathComponent(name))
        copySystemReports(since: launched, from: systemReports, to: reports)
        prune(reports)
        return launched
    }

    /// The session's last line is the clean-exit line.
    static func endedCleanly(_ log: String) -> Bool {
        log.split(whereSeparator: \.isNewline).last?.hasSuffix(cleanExitLine) == true
    }

    /// Copies macOS's Notchd crash reports written after `date`.
    static func copySystemReports(since date: Date, from source: URL, to reports: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("Notchd") && ["ips", "crash", "diag"].contains(file.pathExtension) {
            let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let target = reports.appendingPathComponent(file.lastPathComponent)
            guard let written, written >= date.addingTimeInterval(-2), !fm.fileExists(atPath: target.path) else { continue }
            try? fm.copyItem(at: file, to: target)
        }
    }

    /// Keeps the newest reports only.
    private static func prune(_ reports: URL) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { modified($0) > modified($1) }
        files.dropFirst(maxReports * 2).forEach { try? fm.removeItem(at: $0) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Saved reports, newest first (text reports only; .ips files sit next to them).
    static func reports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: reportsFolder, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []).filter { $0.pathExtension == "txt" }.sorted { modified($0) > modified($1) }
    }

    static func showInFinder() {
        try? FileManager.default.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
        if let latest = reports().first {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Log upkeep

    /// A session can run for weeks: start the log over if something has been filling it.
    private static func trimLog() {
        let log = folder.appendingPathComponent(logName)
        let size = (try? log.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 4_000_000 else { return }
        ftruncate(STDERR_FILENO, 0)
        NSLog("%@\n(log restarted: it had grown past 4 MB)", header())
    }

    // MARK: Freezes

    /// A frozen app looks like a crash to its user, and leaves no crash report. A background timer checks
    /// that the main thread still answers, and notes in the log when it doesn't.
    private static func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "notchd.watchdog", qos: .utility))
        let lock = NSLock()
        var answered = true, misses = 0, reported = false
        var lastTick = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now() + 4, repeating: 2)
        timer.setEventHandler {
            // Every 2 s the main thread is asked to answer. Counting unanswered turns (not clock time)
            // keeps sleep, and a Mac too busy to run this timer either, from looking like a freeze.
            let now = ProcessInfo.processInfo.systemUptime
            let onTime = now - lastTick < 4
            lastTick = now
            lock.lock()
            defer { lock.unlock() }
            if answered {
                if reported { NSLog("[Watchdog] the app is responding again") }
                answered = false
                misses = 0
                reported = false
                DispatchQueue.main.async {
                    lock.lock()
                    answered = true
                    lock.unlock()
                }
            } else if onTime {
                misses += 1
                if misses >= 3, !reported {
                    reported = true
                    NSLog("%@: its main thread hasn't answered for %d s", freezeMarker, misses * 2)
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// Dev: `-debugCrash swift|exception|hang` after 3 s, to try the reports.
    static func debugCrashIfAsked() {
        guard let kind = UserDefaults.standard.string(forKey: "debugCrash") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            switch kind {
            case "exception": NSException(name: .internalInconsistencyException, reason: "debugCrash exception").raise()
            case "hang": Thread.sleep(forTimeInterval: 12)
            default:
                let empty: [Int] = []
                _ = empty[Int(kind) ?? 3]  // Fatal error: Index out of range
            }
        }
    }
}
