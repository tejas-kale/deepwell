import Foundation
import DeepwellModel
import DeepwellLibrary

/// Scoped access to the library folder (LibraryFolderStore in the app, a temp dir in tests).
public protocol LibraryAccessing: Sendable {
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
}
extension LibraryFolderStore: LibraryAccessing {}

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
    public func processPending() async -> RunSummary {
        var summary = RunSummary()
        guard !running else { return summary }
        running = true; defer { running = false }
        guard keys.load() != nil else { summary.missingKey = true; return summary }
        guard now() >= pausedUntil else { summary.pausedUntil = pausedUntil; return summary }

        let scan: Scan
        do { scan = try library.withAccess { Self.scan($0) } } catch { return summary }
        var vocabulary = scan.vocabulary

        for c in scan.pending {
            if let a = attempts[c.item.id], a.next > now() { summary.skippedBackoff += 1; continue }
            do {
                let result = try await tagger.tag(title: c.item.title, text: c.body, vocabulary: vocabulary, librarySize: scan.librarySize)
                let written = try library.withAccess { _ in try Self.apply(result, to: c.url) }
                if written { summary.tagged.append(c.item.id) }
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
    }

    /// Pending: no tags, or no summary (items tagged before summaries existed are re-tagged once, replacing
    /// their old tags). The vocabulary only counts tags of already-summarised items, so those old tags do not
    /// steer the re-tagging.
    static func needsTagging(_ item: Item) -> Bool { item.tags.isEmpty || item.summary == nil }

    static func scan(_ folder: URL) -> Scan {
        var s = Scan(), indexByCanonical: [String: Int] = [:]
        for url in markdownFiles(in: folder) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text) else { continue }
            s.librarySize += 1
            if needsTagging(doc.item) { s.pending.append(Candidate(url: url, item: doc.item, body: doc.body)); continue }
            for t in Set(doc.item.tags) {
                let c = Tagger.canonical(t)
                if let i = indexByCanonical[c] { s.vocabulary[i].count += 1 }
                else { indexByCanonical[c] = s.vocabulary.count; s.vocabulary.append(TagUsage(name: t, count: 1)) }
            }
        }
        return s
    }

    /// Re-reads the file (it may have changed during the API call) and writes only if it still needs tagging.
    static func apply(_ result: TagResult, to url: URL) throws -> Bool {
        // Read and write under one coordinated write, so a sync landing mid-call is not overwritten blindly.
        let written = try CoordinatedFile.update(url) { text in
            var doc = try FrontmatterCodec.decode(text)
            guard needsTagging(doc.item) else { return nil }
            doc.item.tags = result.tags
            doc.item.summary = result.summary
            NewTagFlag.write(result.newTags, to: &doc.item)
            return FrontmatterCodec.encode(doc)
        }
        return written != nil
    }
}
