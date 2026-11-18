import AppKit
import SwiftUI

enum ColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex, rgb, hsl, swiftUI, appKit
    var id: Self { self }
    var title: String {
        ["hex": "HEX", "rgb": "RGB", "hsl": "HSL", "swiftUI": "SwiftUI", "appKit": "NSColor"][rawValue]!
    }
}

/// A picked color in sRGB, 0...1 per channel.
struct PickedColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    private var bytes: (Int, Int, Int) { (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())) }

    func formatted(_ format: ColorFormat) -> String {
        let (r, g, b) = bytes
        switch format {
        case .hex: return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb: return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let (h, s, l) = hsl
            return "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swiftUI: return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
        case .appKit: return String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)", red, green, blue)
        }
    }

    var hsl: (Double, Double, Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        switch maxC {
        case red: h = (green - blue) / d + (green < blue ? 6 : 0)
        case green: h = (blue - red) / d + 2
        default: h = (red - green) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    /// Dark text on light colors and the other way round.
    var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 }
}

@Observable
final class ColorPickerStore {
    static let shared = ColorPickerStore()
    private let file: URL
    private(set) var history: [PickedColor] = [] {
        didSet { try? JSONEncoder().encode(history).write(to: file, options: .atomic) }
    }
    private(set) var picking = false
    /// Last copied color, for the checkmark.
    private(set) var copied: PickedColor?

    init(file: URL = URL.appSupport.appendingPathComponent("colors.json")) {
        self.file = file
        history = Stored.load([PickedColor].self, from: file) ?? []
    }

    /// The system eyedropper: pick any pixel on any screen, then it's copied in your favorite format.
    func pick() {
        guard !picking else { return }
        picking = true
        NSColorSampler().show { [weak self] color in
            guard let self else { return }
            picking = false
            guard let color, let picked = PickedColor(color) else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                self.history.removeAll { $0 == picked }
                self.history.insert(picked, at: 0)
                if self.history.count > 24 { self.history.removeLast(self.history.count - 24) }
            }
            copy(picked)
        }
    }

    func copy(_ color: PickedColor, as format: ColorFormat = Settings.shared.prefs.colorFormat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.formatted(format), forType: .string)
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.15)) { copied = color }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard self?.copied == color else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.copied = nil }
        }
    }

    func remove(_ color: PickedColor) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { history.removeAll { $0 == color } }
    }

    func clear() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { history = [] }
    }
}

struct ColorPickerWidget: View {
    private var store = ColorPickerStore.shared

    var body: some View {
        let format = Settings.shared.prefs.colorFormat
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                Button {
                    store.pick()
                } label: {
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(store.history.first?.color ?? .white.opacity(0.1)))
                        .foregroundStyle(store.history.first.map { $0.isLight ? Color.black : .white } ?? .white)
                }
                .buttonStyle(BouncyButtonStyle())
                .help(Text("Pick a color from the screen"))
                if let last = store.history.first {
                    Text(last.formatted(.hex)).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if store.history.isEmpty {
                Text("Pick a color anywhere on screen. It's copied as \(format.title).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], spacing: 6) {
                        ForEach(store.history, id: \.self) { color in
                            swatch(color)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func swatch(_ color: PickedColor) -> some View {
        Button { store.copy(color) } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.color)
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .overlay {
                    if store.copied == color {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color.isLight ? .black : .white)
                    }
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text(color.formatted(Settings.shared.prefs.colorFormat)))
        .contextMenu {
            ForEach(ColorFormat.allCases) { format in
                Button("Copy \(color.formatted(format))") { store.copy(color, as: format) }
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(color) }
            Button("Clear All", role: .destructive) { store.clear() }
        }
    }
}
