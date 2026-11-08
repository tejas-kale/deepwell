import Foundation
import DeepwellModel
import DeepwellLibrary

/// File-based queue between the Safari extension handler (writer) and the app (reader).
/// Lives in a directory both processes can reach (the shared app-group container).
/// One JSON file per capture; files are written to a temp name then renamed, so the reader
/// never sees a partial file.
public struct CaptureInbox: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    @discardableResult
    public func enqueue(_ payload: CapturePayload) throws -> URL {
        let valid = try payload.validated()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased())"
        let tmp = directory.appendingPathComponent(name + ".tmp")
        let final = directory.appendingPathComponent(name + ".json")
        try JSONEncoder().encode(valid).write(to: tmp)
        try fm.moveItem(at: tmp, to: final)
        return final
    }

    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public struct DrainResult: Equatable {
        public var saved: [URL] = []
        public var rejected: Int = 0   // unreadable payloads, moved to `rejected/`
        public var deferred: Int = 0   // left in place because the library folder isn't available
    }

    /// Turns every queued capture into a Markdown file in the library folder.
    /// Captures stay queued if the library is unavailable, so nothing is lost.
    @discardableResult
    public func drain(into library: LibraryFolderStore) -> DrainResult {
        var result = DrainResult()
        let fm = FileManager.default
        for file in pending() {
            if Self.isLinkFile(file) { continue }   // resolved by the app (see pendingLinks)
            guard let payload = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(CapturePayload.self, from: $0) }),
                  (try? payload.validated()) != nil else {
                let dir = directory.appendingPathComponent("rejected", isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
                result.rejected += 1
                continue
            }
            do {
                let saved = try library.withAccess { folder in
                    try ItemFileWriter.write(payload.makeDocument(), into: folder)
                }
                try? fm.removeItem(at: file)
                result.saved.append(saved)
            } catch {
                result.deferred += 1
            }
        }
        return result
    }
}

extension CaptureInbox {
    /// Links shared from the Share Extension, waiting to be resolved over the network by the app.
    public func pendingLinks() -> [(file: URL, payload: CapturePayload)] {
        pending().compactMap { file in
            guard let p = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(CapturePayload.self, from: $0) }),
                  p.isLink else { return nil }
            return (file, p)
        }
    }

    /// Removes a handled link, or parks it in `unsupported/` so the user's share is not silently lost.
    public func finishLink(_ file: URL, handled: Bool) {
        let fm = FileManager.default
        guard !handled else { try? fm.removeItem(at: file); return }
        let dir = directory.appendingPathComponent("unsupported", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
    }

    static func isLinkFile(_ file: URL) -> Bool {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CapturePayload.self, from: $0) }?.isLink ?? false
    }
}
