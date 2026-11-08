import Foundation
import DeepwellTagging

/// File hand-off from the Share Extension (sandboxed, cannot write the library) to the app (holds the library
/// bookmark). The extension copies shared PDF/EPUB files here; the app stages them into `issues/`.
public struct MagazineInbox: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Copies `file` in (temp name, then rename, so the reader never sees a partial file).
    @discardableResult
    public func enqueue(_ file: URL) throws -> URL {
        guard IssueFormat(pathExtension: file.pathExtension) != nil else { throw MagazineError.unsupportedFile(file.lastPathComponent) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased().prefix(8))-\(file.lastPathComponent)"
        let tmp = directory.appendingPathComponent(name + ".tmp")
        let dest = directory.appendingPathComponent(name)
        try fm.copyItem(at: file, to: tmp)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { IssueFormat(pathExtension: $0.pathExtension) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Stages every queued file into the library; files stay queued if the library is unavailable.
    @discardableResult
    public func drain(into library: LibraryAccessing) -> [IssueStore.Ref] {
        var staged: [IssueStore.Ref] = []
        for f in pending() {
            do {
                let ref = try library.withAccess { try IssueStore.stage(f, intoLibrary: $0) }
                try? FileManager.default.removeItem(at: f)
                staged.append(ref)
            } catch {
                continue
            }
        }
        return staged
    }
}
