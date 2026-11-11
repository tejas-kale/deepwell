import Foundation
import DeepwellModel
import DeepwellLibrary

/// Scoped access to the library folder (LibraryFolderStore in the app, a temp dir in tests).
public protocol LibraryAccessing: Sendable {
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
}
extension LibraryFolderStore: LibraryAccessing {}

/// Which items a pass may tag. The Mac tags the whole library; the phone only what it captured itself (ticket 16).
public struct TaggingScope: Sendable, Equatable {
    /// Item file names (e.g. `2026-11-11-title.md`) the pass is limited to; nil means every file.
    public let fileNames: Set<String>?
    /// Also re-tag items that have tags but no summary (tagged before summaries existed). Mac only: the phone
    /// skips any item that already has tags, so the two devices never both tag one item.
    public let retagMissingSummary: Bool

    public static let wholeLibrary = TaggingScope(fileNames: nil, retagMissingSummary: true)
    /// The phone: only these files, and only while they have no tags.
    public static func capturedHere(_ fileNames: Set<String>) -> TaggingScope {
        TaggingScope(fileNames: fileNames, retagMissingSummary: false)
    }

    public func includes(_ fileName: String) -> Bool { fileNames?.contains(fileName) ?? true }
    public func needsTagging(_ item: Item) -> Bool { item.tags.isEmpty || (retagMissingSummary && item.summary == nil) }
}

/// Tags (and summarises) items in the background. The retry queue is derived from the library itself:
/// any item file with no tags or no summary is pending, so nothing needs persisting and a relaunch resumes.
/// Failures leave the file untouched and back off per file (in memory).
public actor TaggingService {
    public struct RunSummary: Equatable, Sendable {
        public var tagged: [String] = []      // item ids
        public var failed: Int = 0
        public var skippedBackoff: Int = 0
        public var missingKey = false
        public var lastError: String?         // description of the most recent failure, for display
        /// Set when the pass stopped early on a rate limit / overload / network error: nothing more is tried
        /// until this time. Untried items keep no penalty.
        public var pausedUntil: Date?
        /// Limited scopes only: file names in the scope that need nothing more (tagged now, already had tags, or
        /// gone from the library), so the caller can drop them from its queue.
        public var settled: [String] = []
    }

    private let library: LibraryAccessing
    private let tagger: Tagger
    private let keys: APIKeyStore
    private let now: @Sendable () -> Date
    private let baseDelay: TimeInterval
    private var attempts: [String: (count: Int, next: Date)] = [:]
    private var running = false
    /// Service-wide pause after a rate limit (429), overload (529) or network failure. Those are not the item's
    /// fault, so instead of backing off each item (which made a large backlog retry in lockstep bursts and hit the
    /// limit again every time) the whole pass stops and resumes later, doubling up to 15 minutes.
    private var pausedUntil = Date.distantPast
    private var pauseCount = 0

    public init(library: LibraryAccessing, model: TaggingModel, keys: APIKeyStore,
                baseDelay: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.tagger = Tagger(model: model)
        self.keys = keys
        self.baseDelay = baseDelay
        self.now = now
    }

    struct Candidate { var url: URL; var item: Item; var body: String }

    /// One pass over the library. Never throws: errors are counted and retried on a later pass.
    @discardableResult
    public func processPending(scope: TaggingScope = .wholeLibrary) async -> RunSummary {
        var summary = RunSummary()
        guard !running else { return summary }
        running = true; defer { running = false }
        guard keys.load() != nil else { summary.missingKey = true; return summary }
        guard now() >= pausedUntil else { summary.pausedUntil = pausedUntil; return summary }

        let scan: Scan
        do { scan = try library.withAccess { Self.scan($0, scope: scope) } } catch { return summary }
        var vocabulary = scan.vocabulary
        summary.settled = scan.settled

        for c in scan.pending {
            if let a = attempts[c.item.id], a.next > now() { summary.skippedBackoff += 1; continue }
            do {
                let raw = try await tagger.tag(title: c.item.title, text: c.body, vocabulary: vocabulary, librarySize: scan.librarySize)
                let result = try Self.replay(raw, ops: scan.ops)
                let written = try library.withAccess { _ in try Self.apply(result, to: c.url, scope: scope) }
                if written { summary.tagged.append(c.item.id) }
                // Written, or tagged elsewhere meanwhile (apply re-reads the file): either way, done here.
                if scope.fileNames != nil { summary.settled.append(c.url.lastPathComponent) }
                attempts[c.item.id] = nil
                pauseCount = 0
                for t in result.tags {
                    if let i = vocabulary.firstIndex(where: { $0.name == t }) { vocabulary[i].count += 1 }
                    else { vocabulary.append(TagUsage(name: t, count: 1)) }
                }
            } catch TaggingError.missingAPIKey {
                summary.missingKey = true
                break
            } catch where Self.isTransient(error) {
                summary.failed += 1
                summary.lastError = Self.describe(error)
                pauseCount += 1
                pausedUntil = now().addingTimeInterval(min(60 * pow(2, Double(pauseCount - 1)), 900))
                summary.pausedUntil = pausedUntil
                break
            } catch {
                summary.failed += 1
                summary.lastError = "\(c.item.title.prefix(40))…: \(Self.describe(error))"
                let n = (attempts[c.item.id]?.count ?? 0) + 1
                attempts[c.item.id] = (n, now().addingTimeInterval(min(baseDelay * pow(2, Double(n - 1)), 3600)))
            }
        }
        return summary
    }

    /// Errors about the service rather than the item: rate limited, overloaded, server error, or offline.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case TaggingError.api(let status, _): return status == 429 || status == 529 || status >= 500
        case TaggingError.network: return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case TaggingError.api(let status, let message): return "API \(status): \(message)"
        case TaggingError.network(let m): return "network: \(m)"
        case TaggingError.malformedResponse: return "unreadable model response"
        case TaggingError.noTags: return "model returned no usable tags"
        case TaggingError.incomplete(let stop): return stop == "refusal" ? "the model declined this item" : "reply cut off (ran out of tokens)"
        default: return error.localizedDescription
        }
    }

    // MARK: File work (synchronous, runs inside library access)

    static func markdownFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct Scan {
        var pending: [Candidate] = []
        var vocabulary: [TagUsage] = []
        var librarySize = 0
        var settled: [String] = []
        var ops = TagOps()
    }

    /// Pending: no tags, or no summary (items tagged before summaries existed are re-tagged once, replacing
    /// their old tags). The vocabulary only counts tags of already-summarised items, so those old tags do not
    /// steer the re-tagging.
    static func needsTagging(_ item: Item) -> Bool { item.tags.isEmpty || item.summary == nil }

    static func scan(_ folder: URL, scope: TaggingScope = .wholeLibrary) -> Scan {
        var s = Scan(), indexByCanonical: [String: Int] = [:]
        // Ticket 19: the vocabulary offered to the model never includes a renamed, merged or deleted tag.
        let ops = TagOpsLog(library: folder).load()
        s.ops = ops
        let files = markdownFiles(in: folder)
        if let names = scope.fileNames {
            // A scoped file that is gone (deleted, renamed) will never need tagging here.
            s.settled = Array(names.subtracting(files.map(\.lastPathComponent))).sorted()
        }
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text) else { continue }
            s.librarySize += 1
            let inScope = scope.includes(url.lastPathComponent)
            if inScope, scope.needsTagging(doc.item) { s.pending.append(Candidate(url: url, item: doc.item, body: doc.body)); continue }
            if inScope, scope.fileNames != nil { s.settled.append(url.lastPathComponent) }
            // Vocabulary: summarised items only, whatever the scope (an out-of-scope untagged item adds nothing).
            if needsTagging(doc.item) { continue }
            for t in Set(ops.apply(to: doc.item.tags)) {
                let c = Tagger.canonical(t)
                if let i = indexByCanonical[c] { s.vocabulary[i].count += 1 }
                else { indexByCanonical[c] = s.vocabulary.count; s.vocabulary.append(TagUsage(name: t, count: 1)) }
            }
        }
        return s
    }

    /// Ticket 19: the model may still suggest a tag the user renamed, merged or deleted; map it the same way. If nothing
    /// is left (every suggestion was deleted), it is a `noTags` failure, so the per-file back-off applies instead of the
    /// indexer stripping the tags again after every pass.
    static func replay(_ result: TagResult, ops: TagOps) throws -> TagResult {
        guard !ops.isEmpty else { return result }
        var out = result
        out.tags = ops.apply(to: result.tags)
        guard !out.tags.isEmpty else { throw TaggingError.noTags }
        out.newTags = result.newTags.filter { out.tags.contains($0) }
        return out
    }

    /// Re-reads the file (it may have changed during the API call) and writes only if it still needs tagging.
    static func apply(_ result: TagResult, to url: URL, scope: TaggingScope = .wholeLibrary) throws -> Bool {
        // Read and write under one coordinated write, so a sync landing mid-call is not overwritten blindly.
        let written = try CoordinatedFile.update(url) { text in
            var doc = try FrontmatterCodec.decode(text)
            // The other device may have tagged it while the model ran: skip, so tags are never written twice.
            guard scope.needsTagging(doc.item) else { return nil }
            doc.item.tags = result.tags
            doc.item.summary = result.summary
            NewTagFlag.write(result.newTags, to: &doc.item)
            return FrontmatterCodec.encode(doc)
        }
        return written != nil
    }
}
