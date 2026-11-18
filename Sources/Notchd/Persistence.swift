import Foundation

/// Reading the small JSON files the app keeps (to-dos, notes, timers, clipboard history…).
enum Stored {
    /// Decodes `file`. A file that exists but can't be read (cut short by a crash or a full disk, or written
    /// by a newer version) is moved aside as "name.unreadable-<date>" instead of being silently replaced by
    /// an empty list at the next save, so the data can still be recovered by hand.
    static func load<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let aside = file.appendingPathExtension("unreadable-\(stamp)")
            try? FileManager.default.moveItem(at: file, to: aside)
            NSLog("[Stored] %@ couldn't be read (%@); kept as %@", file.lastPathComponent, "\(error)", aside.lastPathComponent)
            return nil
        }
    }
}
