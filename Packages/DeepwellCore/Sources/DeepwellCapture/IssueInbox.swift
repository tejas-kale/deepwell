import Foundation

/// The app-group folder a Share Extension drops PDF/EPUB files into for its app to import (Mac: ticket 08's
/// `MagazineInbox`; iOS: ticket 20). Plain file copies only: no parsing, no network, nothing beyond Foundation, so the
/// iOS Share Extension can link it without the magazine or tagging code.
public struct IssueInbox: Sendable {
    public static let extensions: Set<String> = ["pdf", "epub"]

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func accepts(_ file: URL) -> Bool { extensions.contains(file.pathExtension.lowercased()) }

    /// Copies `file` in (temp name, then rename, so the app never sees a partial file). `name` replaces the file's
    /// base name (e.g. a title the user edited); the extension is kept.
    @discardableResult
    public func enqueue(_ file: URL, name: String? = nil) throws -> URL {
        guard Self.accepts(file) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name.map(Self.safeName).flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
        let fileName = "\(base).\(file.pathExtension.lowercased())"
        let stem = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased().prefix(8))-\(fileName)"
        let tmp = directory.appendingPathComponent(stem + ".tmp")
        let dest = directory.appendingPathComponent(stem)
        try fm.copyItem(at: file, to: tmp)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Queued files, oldest first.
    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter(Self.accepts).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The name the user shared it under: the queued file's name without the timestamp prefix and extension.
    public static func originalTitle(of queued: URL) -> String {
        let stem = queued.deletingPathExtension().lastPathComponent
        if let r = stem.range(of: "^[0-9]+-[0-9a-f]{8}-", options: .regularExpression) { return String(stem[r.upperBound...]) }
        return stem
    }

    static func safeName(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
