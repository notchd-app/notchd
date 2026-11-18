import AppKit
import SwiftUI

/// A version like "0.2.0", compared numerically part by part ("0.10.0" > "0.9.3").
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

struct AvailableUpdate: Equatable {
    var version: String
    var zipURL: URL
    var pageURL: URL
}

/// Checks GitHub Releases in the background. CI only publishes a release whose tag matches the VERSION file,
/// so the latest release tag is the latest shipped version. Installing swaps the app bundle and relaunches.
@Observable
final class Updater {
    static let shared = Updater()
    static let repo = "notchd-app/notchd"

    enum Status: Equatable {
        case idle, checking, upToDate, available(AvailableUpdate), installing, failed(String)
    }

    private(set) var status = Status.idle
    private(set) var lastCheck: Date?
    private var timer: Timer?

    var available: AvailableUpdate? {
        if case let .available(update) = status { update } else { nil }
    }

    /// Checks shortly after launch, then every 6 hours, while "Check automatically" is on.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.autoCheck() }
    }

    private func autoCheck() {
        guard Settings.shared.prefs.autoCheckUpdates else { return }
        check()
    }

    func check() {
        guard status != .checking, status != .installing else { return }
        status = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { self?.finishCheck(result) }
        }.resume()
    }

    private func finishCheck(_ result: Result<AvailableUpdate?, Error>) {
        lastCheck = Date()
        switch result {
        case let .success(update?):
            withAnimation(.notchOpen) { status = .available(update) }
        case .success(nil):
            status = .upToDate
        case let .failure(error):
            status = .failed(error.localizedDescription)
        }
    }

    /// nil when the latest release isn't newer than this build (or has no zip attached).
    static func parse(data: Data?, response: URLResponse?, error: Error?,
                      current: AppVersion? = .current) -> Result<AvailableUpdate?, Error> {
        if let error { return .failure(error) }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return .success(nil) }  // no release yet
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let latest = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            return .failure(UpdateError(L("Unexpected answer from GitHub.")))
        }
        guard let current, current < latest else { return .success(nil) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return .success(nil) }
        return .success(AvailableUpdate(version: latest.description, zipURL: zipURL, pageURL: page))
    }

    /// Download → unzip → check it's really notchd → swap the bundle once we've quit → relaunch.
    func install() {
        guard let update = available else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { status = .installing }
        URLSession.shared.downloadTask(with: update.zipURL) { [weak self] file, _, error in
            let result: Result<URL, Error> = {
                guard let file else { return .failure(error ?? UpdateError(L("Download failed."))) }
                return Result { try Self.unpack(file) }
            }()
            DispatchQueue.main.async {
                switch result {
                case let .success(newApp): self?.swapAndRelaunch(with: newApp)
                case let .failure(error): self?.status = .failed(error.localizedDescription)
                }
            }
        }.resume()
    }

    private static func unpack(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchd-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("Notchd.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(L("The download isn't a notchd build."))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        guard signedLikeUs(app) else { throw UpdateError(L("The download isn't signed with notchd's certificate.")) }
        return app
    }

    /// When we carry a real certificate, an update must be signed with the same one: a hijacked release
    /// can't slip in a foreign build. Ad-hoc builds (pinned to their own hash) can't check this, so they don't.
    static func signedLikeUs(_ app: URL, current: URL = Bundle.main.bundleURL) -> Bool {
        var currentCode: SecStaticCode?, newCode: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess, let currentCode,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        if (text as String?)?.contains("cdhash") ?? true { return true }  // ad hoc: nothing to pin
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        return SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess
    }

    private func swapAndRelaunch(with newApp: URL) {
        // Quitting is refused during a capture: the swap would then wait and strike at some later quit.
        guard !CaptureManager.shared.isActive else {
            status = .failed(L("Finish your capture, then try again."))
            return
        }
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            status = .failed(String(localized: "Can't write to \(current.deletingLastPathComponent().path). Download it from GitHub instead."))
            return
        }
        // A detached shell waits for us to quit, swaps the bundles, and opens the new one.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path)" && mv "\(newApp.path)" "\(current.path)" && open "\(current.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        withAnimation(.notchClose) { status = .idle }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed.") }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Live activity

struct UpdateActivityLeading: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.green)
            .symbolEffect(.bounce, value: Updater.shared.available?.version)
    }
}

/// Install button; a spinner while the update downloads.
struct UpdateActivityTrailing: View {
    private var updater = Updater.shared

    var body: some View {
        if updater.status == .installing {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            Button {
                updater.install()
                Haptics.tap()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 20)
                    .background(Pill().fill(.green))
            }
            .buttonStyle(BouncyButtonStyle())
            .help("Install notchd \(updater.available?.version ?? "") and relaunch")
        }
    }
}
