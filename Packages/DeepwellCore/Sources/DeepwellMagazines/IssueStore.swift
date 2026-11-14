import Foundation
import CryptoKit
import DeepwellModel
import DeepwellLibrary

/// Originals live in `<library>/issues/<issueID>-<slug>.<pdf|epub>`. The issue id is the first 16 hex chars of the
/// file's SHA-256, so importing the same file twice stores it once.
public enum IssueStore {
    public static let folderName = "issues"

    public struct Ref: Equatable, Sendable {
        public var id: String
        public var url: URL
        public var isNew: Bool
    }

    public static func issuesFolder(in library: URL) -> URL { library.appendingPathComponent(folderName, isDirectory: true) }

    /// Copies `source` into `<library>/issues/` (no-op if the same bytes are already there). Fast; no model, no parsing.
    public static func stage(_ source: URL, intoLibrary library: URL, fileManager fm: FileManager = .default) throws -> Ref {
        guard IssueFormat(pathExtension: source.pathExtension) != nil else { throw MagazineError.unsupportedFile(source.lastPathComponent) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let existing = url(for: id, in: library, fileManager: fm) { return Ref(id: id, url: existing, isNew: false) }
        let folder = issuesFolder(in: library)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = ItemFileWriter.slug(source.deletingPathExtension().lastPathComponent)
        let dest = folder.appendingPathComponent("\(id)-\(slug).\(source.pathExtension.lowercased())")
        let tmp = folder.appendingPathComponent(".\(id).tmp")
        try? fm.removeItem(at: tmp)
        try data.write(to: tmp)
        try fm.moveItem(at: tmp, to: dest)
        return Ref(id: id, url: dest, isNew: true)
    }

    public static func url(for issueID: String, in library: URL, fileManager fm: FileManager = .default) -> URL? {
        all(in: library, fileManager: fm).first { $0.id == issueID }?.url
    }

    public static func all(in library: URL, fileManager fm: FileManager = .default) -> [Ref] {
        let files = (try? fm.contentsOfDirectory(at: issuesFolder(in: library), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in
            guard IssueFormat(pathExtension: f.pathExtension) != nil,
                  let r = f.lastPathComponent.range(of: "^[0-9a-f]{16}-", options: .regularExpression) else { return nil }
            return Ref(id: String(f.lastPathComponent[r].dropLast()), url: f, isNew: false)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}

/// Position of an article inside its issue, stored as `issue_start` / `issue_end` (0-based unit index: PDF page or
/// EPUB unit, `EPUBPackage.units`) in the article's frontmatter via `Item.extraFrontmatter`.
public enum IssuePosition {
    public static func read(_ item: Item) -> (start: Int, end: Int)? {
        func val(_ key: String) -> Int? {
            item.extraFrontmatter.first { $0.hasPrefix(key + ":") }
                .flatMap { Int($0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)) }
        }
        guard let s = val("issue_start") else { return nil }
        return (s, val("issue_end") ?? s)
    }

    public static func write(start: Int, end: Int, to item: inout Item) {
        item.extraFrontmatter.removeAll { $0.hasPrefix("issue_start:") || $0.hasPrefix("issue_end:") }
        item.extraFrontmatter.append("issue_start: \(start)")
        item.extraFrontmatter.append("issue_end: \(end)")
    }
}
