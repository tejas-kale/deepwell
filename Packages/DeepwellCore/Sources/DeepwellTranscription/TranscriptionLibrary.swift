import Foundation
import DeepwellModel
import DeepwellLibrary

/// The queue's view of the library: find items that need transcripts, read and rewrite them.
public protocol TranscriptionLibrary {
    func itemsNeedingTranscript() throws -> [PersistedJob]
    func load(id: String) throws -> ItemDocument?
    func save(_ doc: ItemDocument) throws
    /// Ticket 20: writes `device`'s claim into the item if it still needs a transcript and no other device holds a
    /// live claim. True if the claim is now `device`'s.
    func claim(id: String, device: String, at: Date) throws -> Bool
    /// Drops `device`'s claim (the job failed or was cancelled), leaving `needs_transcript` in place.
    func release(id: String, device: String) throws
}

/// Runs a body with access to the library folder (security-scoped in the app).
public protocol FolderAccessing {
    func withFolder<T>(_ body: (URL) throws -> T) throws -> T
}

extension LibraryFolderStore: FolderAccessing {
    public func withFolder<T>(_ body: (URL) throws -> T) throws -> T { try withAccess(body) }
}

/// Plain-folder implementation: scans `*.md` files and rewrites the file in place.
public struct FolderTranscriptionLibrary: TranscriptionLibrary {
    private let access: FolderAccessing
    private let itemTypes: Set<ItemType>?
    public init(access: FolderAccessing, itemTypes: Set<ItemType>? = nil) {
        self.access = access
        self.itemTypes = itemTypes
    }

    private func files(in folder: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func parse(_ url: URL) -> ItemDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? FrontmatterCodec.decode(text)
    }

    public func itemsNeedingTranscript() throws -> [PersistedJob] {
        try access.withFolder { folder in
            files(in: folder).compactMap { parse($0) }.filter { $0.item.needsTranscript && (itemTypes?.contains($0.item.type) ?? true) }
                .sorted { $0.item.capturedAt < $1.item.capturedAt }
                .map { PersistedJob(id: $0.item.id, title: $0.item.title, claim: $0.item.processingClaim) }
        }
    }

    private func locate(_ id: String, in folder: URL) -> (URL, ItemDocument)? {
        for f in files(in: folder) { if let d = parse(f), d.item.id == id { return (f, d) } }
        return nil
    }

    public func load(id: String) throws -> ItemDocument? {
        try access.withFolder { locate(id, in: $0)?.1 }
    }

    public func save(_ doc: ItemDocument) throws {
        try access.withFolder { folder in
            guard let (url, _) = locate(doc.item.id, in: folder) else { throw TranscriptionError.itemMissing }
            try CoordinatedFile.write(FrontmatterCodec.encode(doc), to: url)
        }
    }

    public func claim(id: String, device: String, at now: Date) throws -> Bool {
        try access.withFolder { folder in
            guard let (url, _) = locate(id, in: folder) else { return false }
            var claimed = false
            // One coordinated read-modify-write, so a change arriving from iCloud isn't overwritten.
            try CoordinatedFile.update(url) { text in
                var doc = try FrontmatterCodec.decode(text)
                guard doc.item.needsTranscript else { return nil }
                if let c = doc.item.processingClaim, c.blocks(device, at: now) { return nil }
                doc.item.processingClaim = ProcessingClaim(device: device, at: now)
                claimed = true
                return FrontmatterCodec.encode(doc)
            }
            return claimed
        }
    }

    public func release(id: String, device: String) throws {
        try access.withFolder { folder in
            guard let (url, _) = locate(id, in: folder) else { return }
            try CoordinatedFile.update(url) { text in
                var doc = try FrontmatterCodec.decode(text)
                guard let c = doc.item.processingClaim, c.device == ProcessingClaim(device: device, at: Date()).device else { return nil }
                doc.item.processingClaim = nil
                return FrontmatterCodec.encode(doc)
            }
        }
    }
}
