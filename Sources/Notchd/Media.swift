import AppKit
import CoreImage
import SwiftUI

struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var bundleID = ""
    var playing = false
    var duration: Double = 0
    var elapsed: Double = 0
    var timestamp = Date()
    var artwork: NSImage?
    var tint: Color = .white

    /// Icon of the app playing, for the badge on the artwork.
    var appIcon: NSImage? { MediaManager.appIcon(bundleID) }

    /// Playback position now, extrapolated from the last report.
    func position(at date: Date) -> Double {
        guard playing else { return elapsed }
        return min(duration, elapsed + date.timeIntervalSince(timestamp))
    }

    static let sample = NowPlaying(title: "Song Title", artist: "Artist", playing: true, duration: 200,
                                   elapsed: 60, tint: .pink)
}

/// Now Playing through mediaremote-adapter: Apple's perl is entitled to MediaRemote on macOS 15.4+,
/// so it loads the bundled helper framework and streams JSON lines to us.
@Observable
final class MediaManager {
    static let shared = MediaManager()

    private(set) var nowPlaying: NowPlaying?
    /// True while the media live activity should be on screen (playing, or paused less than the timeout ago).
    private(set) var showActivity = false
    /// Players seen this session that are still running, most recent first.
    private(set) var sources: [String] = []
    /// The player the system currently routes Now Playing to (may differ from `nowPlaying` when pinned).
    private var systemSource = ""

    private var process: Process?
    private var state: [String: Any] = [:]
    private var buffer = Data()
    private var hideWork: DispatchWorkItem?
    private var restartDelay = 1.0

    private var resources: URL? { Bundle.main.resourceURL }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier, sources.contains(id) else { return }
            sources.removeAll { $0 == id }
            if nowPlaying?.bundleID == id { apply() }  // a pinned player quit: follow the system again
        }
    }

    func start() {
        guard let resources,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("mediaremote-adapter.pl").path)
        else { return NSLog("[Media] adapter not bundled") }
        // A killed Notchd leaves its perl child running: clean up before starting a new stream.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", resources.appendingPathComponent("mediaremote-adapter.pl").path + " .* stream"]
        try? pkill.run()
        pkill.waitUntilExit()

        let process = adapter(["stream", "--debounce=50"])
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At end of file the handler is called over and over with nothing: stop, or it spins a core
            // and floods the main thread for as long as the app runs.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        // The adapter dies with its parent only if we kill it; restart it if it crashes. One that keeps
        // dying right away is retried less and less often (2 s, 4 s … 2 min) instead of forever every 2 s.
        let startedAt = Date()
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                let lived = Date().timeIntervalSince(startedAt)
                self.restartDelay = lived > 30 ? 2 : min(self.restartDelay * 2, 120)
                NSLog("[Media] helper exited (status %d) after %.0f s; restarting in %.0f s", finished.terminationStatus, lived,
                      self.restartDelay)
                self.buffer.removeAll()
                self.state = [:]
                self.apply()
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartDelay) { self.start() }
            }
        }
        do { try process.run() } catch { return NSLog("[Media] failed to start adapter: \(error)") }
        self.process = process
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    /// `send` command ids from the adapter: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    func send(_ command: Int) {
        try? adapter(["send", "\(command)"]).run()
    }

    func togglePlayPause() { command(2, script: "playpause") }
    func next() { command(4, script: "next track") }
    func previous() { command(5, script: "previous track") }

    /// MediaRemote only drives the system's current player. When the widget is pinned to another one,
    /// Music and Spotify are scriptable, so they get an Apple Event instead.
    private func command(_ id: Int, script: String) {
        if let shown = nowPlaying?.bundleID, shown != systemSource, Self.scriptable.contains(shown) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application id \"\(shown)\" to \(script)"]
            try? process.run()
        } else {
            send(id)
        }
    }

    private static let scriptable: Set = ["com.apple.Music", "com.spotify.client"]

    /// Shows a player in the widget (and keeps it there) or follows the system again (nil).
    func pin(_ bundleID: String?) {
        Settings.shared.prefs.mediaPinnedSource = bundleID
        apply()
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    func openApp() {
        guard let id = nowPlaying?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Players offered when nothing is playing, if installed.
    static let knownPlayers = ["com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.tidal.desktop",
                               "com.deezer.deezer-desktop", "com.colliderli.iina", "org.videolan.vlc"]

    func seek(to seconds: Double) {
        try? adapter(["seek", "\(Int(seconds * 1_000_000))"]).run()
        nowPlaying?.elapsed = seconds
        nowPlaying?.timestamp = Date()
    }

    private func adapter(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources!.appendingPathComponent("mediaremote-adapter.pl").path,
                             resources!.appendingPathComponent("MediaRemoteAdapter.framework").path] + args
        return process
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // A line is a few hundred KB at most (artwork included): anything far bigger is a helper gone wrong.
        if buffer.count > 32_000_000 { buffer.removeAll() }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            if json["diff"] as? Bool == true {
                for (key, value) in payload {
                    if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
                }
            } else {
                state = payload
            }
            apply()
        }
    }

    private func apply() {
        // Browsers play through helper processes: name the browser, not its helper.
        let bundleID = state["parentApplicationBundleIdentifier"] as? String ?? state["bundleIdentifier"] as? String ?? ""
        systemSource = bundleID
        if !bundleID.isEmpty, sources.first != bundleID {
            sources.removeAll { $0 == bundleID }
            sources.insert(bundleID, at: 0)
        }
        // Pinned to another player that's still running: keep showing it.
        if let pinned = Settings.shared.prefs.mediaPinnedSource, pinned != bundleID,
           !NSRunningApplication.runningApplications(withBundleIdentifier: pinned).isEmpty {
            return
        }
        guard let title = state["title"] as? String, !title.isEmpty else {
            update(nil)
            return
        }
        var info = NowPlaying()
        info.title = title
        info.artist = state["artist"] as? String ?? ""
        info.album = state["album"] as? String ?? ""
        info.bundleID = bundleID
        info.playing = state["playing"] as? Bool ?? false
        // Live streams can report infinite or absurd lengths, which trap when turned into whole seconds.
        func sane(_ value: Any?) -> Double {
            let number = value as? Double ?? 0
            return number.isFinite && number >= 0 && number < 1_000_000 ? number : 0
        }
        info.duration = sane(state["duration"])
        info.elapsed = min(sane(state["elapsedTime"]), info.duration > 0 ? info.duration : 1_000_000)
        if let ts = state["timestamp"] as? String { info.timestamp = ISO8601DateFormatter().date(from: ts) ?? Date() }

        // Decoding artwork is the expensive bit: reuse it while the track doesn't change.
        if let current = nowPlaying, current.title == info.title, current.artist == info.artist, current.artwork != nil,
           state["artworkData"] != nil {
            info.artwork = current.artwork
            info.tint = current.tint
        } else if let base64 = state["artworkData"] as? String, let data = Data(base64Encoded: base64),
                  let image = NSImage(data: data) {
            info.artwork = image
            info.tint = image.averageColor
        }
        update(info)
    }

    private func update(_ info: NowPlaying?) {
        let wasPlaying = nowPlaying?.playing ?? false
        let songChanged = info != nil && nowPlaying != nil && (info?.title != nowPlaying?.title || info?.artist != nowPlaying?.artist)
        nowPlaying = info
        LyricsStore.shared.trackChanged(info)
        if songChanged, info?.playing == true, Settings.shared.prefs.peekOnSongChange { ActivityCenter.shared.peek() }
        let playing = info?.playing ?? false

        if playing {
            hideWork?.cancel()
            hideWork = nil
            if !showActivity { withAnimation(.notchOpen) { showActivity = true } }
        } else if showActivity, wasPlaying || info == nil, hideWork == nil, !Settings.shared.prefs.demoMode {
            let work = DispatchWorkItem { [weak self] in
                self?.hideWork = nil
                withAnimation(.notchClose) { self?.showActivity = false }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.prefs.inactivityTimeout, execute: work)
        }
    }
}

extension NSImage {
    /// Average artwork color, brightened so it reads on black.
    var averageColor: Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s * 1.2, 1), brightness: max(b, 0.75))
    }
}

// MARK: - Live activity views

struct MediaActivityLeading: View {
    let info: NowPlaying
    var cornerRadius = Settings.shared.prefs.albumCornerRadius

    var body: some View {
        Artwork(image: info.artwork, cornerRadius: cornerRadius * 22 / 60)
            .frame(width: 22, height: 22)
            .id(info.title)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .scaleEffect(info.playing ? 1 : 0.85)
            .opacity(info.playing ? 1 : 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: info.playing)
    }
}

struct Artwork: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct MediaEffectView: View {
    let info: NowPlaying
    var effect = Settings.shared.prefs.mediaEffect
    var colored = Settings.shared.prefs.coloredEffects

    var body: some View {
        let tint = colored ? info.tint : .white
        Group {
            switch effect {
            case .spectrograph: Spectrograph(playing: info.playing, tint: tint)
            case .waves: Waves(playing: info.playing, tint: tint)
            case .vibratingCircle: VibratingCircle(playing: info.playing, tint: tint)
            case .gif:
                if let url = GIFStore.shared.url {
                    GIFEffect(url: url, playing: info.playing)
                } else {
                    Spectrograph(playing: info.playing, tint: tint)
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
    }
}

/// Effects follow the system volume: quieter music, smaller bars; flat when muted.
extension Spectrograph {
    static var gain: CGFloat { 0.3 + 0.7 * AudioVolume.shared.loudness }
}

/// Fake audio spectrograph: bars bouncing on springs. Flat when paused.
struct Spectrograph: View {
    let playing: Bool
    let tint: Color
    @Local private var levels: [CGFloat] = [0.3, 0.5, 0.4, 0.6]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 4 + 12 * (playing ? levels[i] * Self.gain : 0))
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: AudioVolume.shared.loudness)
        .task(id: playing) {
            while playing, !Task.isCancelled {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                    levels = levels.map { _ in .random(in: 0.15...1) }
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playing)
    }
}

/// Two sine waves drifting past each other. A flat line when paused.
struct Waves: View {
    let playing: Bool
    let tint: Color
    @Local private var amplitude: CGFloat

    init(playing: Bool, tint: Color) {
        self.playing = playing
        self.tint = tint
        _amplitude = Local(initialValue: playing ? 1 : 0)
    }

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for (speed, alpha) in [(5.0, 1.0), (-3.5, 0.45)] {
                    let path = Self.wave(in: size, time: t, speed: speed, amplitude: amplitude * Spectrograph.gain)
                    context.stroke(path, with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .frame(width: 26, height: 16)
        .onChange(of: playing) { _, value in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { amplitude = value ? 1 : 0 }
        }
    }

    /// A sine wave pinned at both ends. Split into steps: older compilers time out type-checking it inline.
    private static func wave(in size: CGSize, time: Double, speed: Double, amplitude: CGFloat) -> Path {
        var path = Path()
        let middle: CGFloat = size.height / 2
        let height: CGFloat = amplitude * size.height / 2.4
        for x in stride(from: CGFloat(0), through: size.width, by: 1) {
            let progress: CGFloat = x / size.width
            let envelope: CGFloat = sin(progress * .pi)
            let phase: CGFloat = progress * 2.4 * .pi + CGFloat(time * speed)
            let point = CGPoint(x: x, y: middle + sin(phase) * envelope * height)
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// A dot that throbs to a fake beat.
struct VibratingCircle: View {
    let playing: Bool
    let tint: Color
    @Local private var scale: CGFloat = 0.6

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.3)).scaleEffect(scale * 1.25)
            Circle().fill(tint).scaleEffect(scale * 0.8)
        }
        .frame(width: 16, height: 16)
        .task(id: playing) {
            guard playing else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { scale = 0.5 }
                return
            }
            while !Task.isCancelled {
                let peak = 0.55 + 0.45 * Spectrograph.gain
                withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) { scale = .random(in: (peak - 0.2)...peak) }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { scale = .random(in: 0.5...0.65) }
                try? await Task.sleep(for: .milliseconds(.random(in: 150...320)))
            }
        }
    }
}

// MARK: - Nook widget

struct MediaWidget: View {
    private var media = MediaManager.shared
    @Local private var scrubbing: Double?

    private var showingLyrics: Bool {
        Settings.shared.prefs.lyricsEnabled && Settings.shared.prefs.mediaShowLyrics
    }

    var body: some View {
        let info = media.nowPlaying
        Group {
            if let info {
                HStack(spacing: 12) {
                    artwork(info)
                    VStack(alignment: .leading, spacing: 4) {
                        if showingLyrics {
                            LyricsView(info: info)
                                .frame(maxHeight: .infinity)
                                .transition(.blurPop)
                        } else {
                            Text(info.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(info.artist.isEmpty ? " " : info.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if info.duration > 0 { progress(info) }
                        }
                        controls(info)
                    }
                }
            } else {
                PlayerLauncher()
            }
        }
        .overlay(alignment: .topTrailing) { SourcePicker() }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: info?.title)
    }

    /// Artwork with the player's icon in the corner; a click brings the player forward.
    private func artwork(_ info: NowPlaying) -> some View {
        Button(action: media.openApp) {
            Artwork(image: info.artwork, cornerRadius: Settings.shared.prefs.albumCornerRadius * 1.2)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if let icon = info.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24).offset(x: 7, y: 7)
                    }
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Open \(MediaManager.appName(info.bundleID))"))
        .scaleEffect(info.playing ? 1 : 0.9)
        .shadow(color: info.tint.opacity(0.35), radius: 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: info.playing)
        .id(info.title)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func progress(_ info: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let position = scrubbing ?? info.position(at: timeline.date)
            HStack(spacing: 6) {
                Text(Self.time(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(info.tint).frame(width: geo.size.width * position / info.duration)
                    }
                    .frame(height: scrubbing == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                scrubbing = min(max(0, value.location.x / geo.size.width), 1) * info.duration
                            }
                        }
                        .onEnded { _ in
                            if let scrubbing { media.seek(to: scrubbing) }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { scrubbing = nil }
                        })
                }
                .frame(height: 12)
                Text(Self.time(info.duration))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(_ info: NowPlaying) -> some View {
        HStack(spacing: 0) {
            if Settings.shared.prefs.lyricsEnabled {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        Settings.shared.prefs.mediaShowLyrics.toggle()
                    }
                    Haptics.tap()
                } label: {
                    Image(systemName: showingLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(showingLyrics ? AnyShapeStyle(info.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(showingLyrics ? Text("Hide lyrics") : Text("Show lyrics"))
            }
            Spacer(minLength: 4)
            HStack(spacing: 18) {
                Button(action: media.previous) { Image(systemName: "backward.fill") }
                Button(action: media.togglePlayPause) {
                    Image(systemName: info.playing ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 18))
                }
                Button(action: media.next) { Image(systemName: "forward.fill") }
            }
            Spacer(minLength: 4)
            AudioOutputButton()
        }
        .font(.system(size: 13))
        .buttonStyle(BouncyButtonStyle())
        .frame(maxWidth: .infinity)
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Nothing playing: offers the players installed on this Mac.
private struct PlayerLauncher: View {
    private let players = MediaManager.knownPlayers
        .compactMap { id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (id, $0) } }
        .prefix(3)

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("Nothing playing").font(.system(size: 13, weight: .semibold))
                if !players.isEmpty {
                    Text("Start some music?").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                ForEach(Array(players), id: \.0) { id, url in
                    Button {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    } label: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(MediaManager.appName(id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small player icons when several are around: click one to stick to it, again to follow the system.
private struct SourcePicker: View {
    private var media = MediaManager.shared

    var body: some View {
        let pinned = Settings.shared.prefs.mediaPinnedSource
        if media.sources.count > 1 {
            HStack(spacing: 3) {
                ForEach(media.sources.prefix(4), id: \.self) { id in
                    Button {
                        media.pin(pinned == id ? nil : id)
                        Haptics.tap()
                    } label: {
                        if let icon = MediaManager.appIcon(id) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                                .padding(2)
                                .background(Circle().fill(.white.opacity(pinned == id ? 0.25 : 0)))
                                .opacity(media.nowPlaying?.bundleID == id ? 1 : 0.5)
                        }
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(pinned == id ? Text("Pinned to \(MediaManager.appName(id)). Click to follow the system again.")
                                       : Text("Show \(MediaManager.appName(id))"))
                }
            }
            .padding(.top, -6)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - GIF effect

/// The user's GIF lives in Application Support so it survives the original file moving.
@Observable
final class GIFStore {
    static let shared = GIFStore()
    private let file = URL.appSupport.appendingPathComponent("media-effect.gif")
    /// Bumped on every change so views reload the image.
    private(set) var revision = 0

    var url: URL? {
        _ = revision  // observe changes
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    @discardableResult
    func install(from source: URL) -> Bool {
        try? FileManager.default.removeItem(at: file)
        defer { revision += 1 }
        do {
            try FileManager.default.copyItem(at: source, to: file)
            return true
        } catch {
            NSLog("[GIF] install failed: \(error)")
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
        revision += 1
    }
}

struct GIFEffect: View {
    let url: URL
    let playing: Bool
    private var prefs: Prefs { Settings.shared.prefs }

    init(url: URL, playing: Bool) {
        self.url = url
        self.playing = playing
    }

    var body: some View {
        AnimatedImage(url: url, playing: playing, pixelPerfect: prefs.gifPixelPerfect, revision: GIFStore.shared.revision)
            .frame(width: 26 * prefs.gifScale, height: 26 * prefs.gifScale)
            .offset(x: prefs.gifOffsetX, y: prefs.gifOffsetY)
            .opacity(playing ? 1 : 0.5)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
    }
}

/// NSImageView plays GIFs natively; nearest-neighbour filtering keeps pixel art crisp.
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    let playing: Bool
    let pixelPerfect: Bool
    let revision: Int

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.loaded != revision || view.image == nil {
            view.image = NSImage(contentsOf: url)
            context.coordinator.loaded = revision
        }
        view.animates = playing
        let filter: CALayerContentsFilter = pixelPerfect ? .nearest : .linear
        view.layer?.magnificationFilter = filter
        view.layer?.minificationFilter = filter
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = -1 }
}
