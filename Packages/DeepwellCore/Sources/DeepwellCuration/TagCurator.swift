import Foundation
import DeepwellModel
import DeepwellIndex
import DeepwellTagging
import DeepwellLibrary

public struct CurationResult: Equatable, Sendable {
    /// Library-relative paths of files that were rewritten (and re-indexed).
    public var updated: [String] = []
    /// Files that could not be rewritten (missing, evicted, unreadable), with the reason.
    public var failed: [String: String] = [:]
}

public enum CurationError: Error, Equatable {
    case emptyName
}

/// Tag curation: rename, merge and delete tags across every affected item file, then refresh the index
/// rows for those files so the UI sees the change without waiting for a folder sync. The Markdown files are
/// the source of truth: each file is re-read before it is changed.
///
/// Tags match case/separator-insensitively (`Tagger.canonical`), so "Machine Learning" and "machine-learning"
/// are one tag. The `new_tags` flag is updated too: renaming, merging away or deleting a tag clears its flag
/// (the user has reviewed it); `acceptNew` clears the flag and keeps the tag.
///
/// Ticket 19: rename, merge and delete first append a `TagOp` to `<library>/.deepwell/tag-ops.jsonl` (coordinated),
/// then rewrite the files through the same `TagOps` replay the other devices use. So a file this pass missed (evicted,
/// or a stale copy still on another device) is healed later by `LibrarySync` or `ConflictMerge`.
public struct TagCurator: Sendable {
    public let root: URL
    public let index: LibraryIndex
    /// Recorded in each op (`SharedConfig.deviceName` in the apps).
    public let device: String

    public init(root: URL, index: LibraryIndex, device: String = "unknown") {
        self.root = root
        self.index = index
        self.device = device
    }

    public var log: TagOpsLog { TagOpsLog(library: root) }

    /// Renames `tag` to `newName`. If `newName` matches an existing tag (ignoring case/separators) this is a merge.
    @discardableResult
    public func rename(_ tag: String, to newName: String) throws -> CurationResult {
        try replace(tag, with: try resolvedTarget(newName), kind: .rename)
    }

    /// Merges `source` into `target`; `target` is kept verbatim as the surviving spelling.
    @discardableResult
    public func merge(_ source: String, into target: String) throws -> CurationResult {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Tagger.canonical(name).isEmpty else { throw CurationError.emptyName }
        return try replace(source, with: name, kind: .merge)
    }

    /// Removes `tag` from every item. Items left with no tags will be picked up by auto-tagging again.
    @discardableResult
    public func delete(_ tag: String) throws -> CurationResult {
        try replace(tag, with: nil, kind: .delete)
    }

    /// Clears the new-tag flag for `tag` on every item (the tag stays).
    @discardableResult
    public func acceptNew(_ tag: String) throws -> CurationResult {
        let key = Tagger.canonical(tag)
        return try rewrite(candidate: { $0.newTags.contains { Tagger.canonical($0) == key } }) { item in
            NewTagFlag.write(NewTagFlag.read(item).filter { Tagger.canonical($0) != key }, to: &item)
        }
    }

    /// Clears every new-tag flag in the library.
    @discardableResult
    public func acceptAllNew() throws -> CurationResult {
        try rewrite(candidate: { !$0.newTags.isEmpty }) { NewTagFlag.write([], to: &$0) }
    }

    // MARK: Internals

    private func resolvedTarget(_ name: String) throws -> String {
        let canonical = Tagger.canonical(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !canonical.isEmpty else { throw CurationError.emptyName }
        let existing = try index.tagSummaries().first { Tagger.canonical($0.name) == canonical }
        return existing?.name ?? canonical
    }

    private func replace(_ tag: String, with target: String?, kind: TagOp.Kind) throws -> CurationResult {
        let key = Tagger.canonical(tag)
        guard !key.isEmpty else { return CurationResult() }
        // Renaming a tag to its own spelling changes nothing: no op.
        if let target, target == tag { return CurationResult() }
        let op = TagOp(device: device, op: kind, from: tag, to: target)
        // Logged first: if a file can't be rewritten now, the log still heals it later.
        try log.append(op)
        let replay = TagOps([op])
        // The source tag has been reviewed; other flags survive as long as their tag does (`TagOps.apply(to: &Item)`).
        return try rewrite(candidate: { $0.item.tags.contains { Tagger.canonical($0) == key } }) { replay.apply(to: &$0) }
    }

    /// For each indexed item passing `candidate`, re-reads the file, applies `change`, and if that changed
    /// anything writes the file and updates its index row. One bad file does not stop the rest.
    private func rewrite(candidate: (IndexedItem) -> Bool, change: (inout Item) -> Void) throws -> CurationResult {
        var result = CurationResult()
        for entry in try index.list() where candidate(entry) {
            let url = root.appendingPathComponent(entry.relativePath)
            do {
                var changed: ItemDocument?
                try CoordinatedFile.update(url) { text in
                    var doc = try FrontmatterCodec.decode(text)
                    let before = doc.item
                    change(&doc.item)
                    if doc.item == before { return nil }
                    changed = doc
                    return FrontmatterCodec.encode(doc)
                }
                guard let doc = changed else { continue }
                let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                try index.upsert(path: entry.relativePath, document: doc, modified: mtime)
                result.updated.append(entry.relativePath)
            } catch {
                result.failed[entry.relativePath] = error.localizedDescription
            }
        }
        return result
    }
}
