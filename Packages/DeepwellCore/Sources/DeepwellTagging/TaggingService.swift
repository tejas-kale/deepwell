import Foundation
import DeepwellModel
import DeepwellLibrary

/// Scoped access to the library folder (LibraryFolderStore in the app, a temp dir in tests).
public protocol LibraryAccessing: Sendable {
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
}
extension LibraryFolderStore: LibraryAccessing {}

/// Tags untagged items in the background. The retry queue is derived from the library itself:
/// any item file with no tags is pending, so nothing needs persisting and a relaunch resumes naturally.
/// Failures leave the file untouched and back off per file (in memory).
public actor TaggingService {
    public struct RunSummary: Equatable, Sendable {
        public var tagged: [String] = []      // item ids
        public var failed: Int = 0
        public var skippedBackoff: Int = 0
        public var missingKey = false
        public var lastError: String?         // description of the most recent failure, for display
    }

    private let library: LibraryAccessing
    private let tagger: Tagger
    private let keys: APIKeyStore
    private let now: @Sendable () -> Date
    private let baseDelay: TimeInterval
    private var attempts: [String: (count: Int, next: Date)] = [:]
    private var running = false

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

        let scan: (pending: [Candidate], vocabulary: [String])
        do { scan = try library.withAccess { Self.scan($0) } } catch { return summary }
        var vocabulary = scan.vocabulary

        for c in scan.pending {
            if let a = attempts[c.item.id], a.next > now() { summary.skippedBackoff += 1; continue }
            do {
                let result = try await tagger.tag(title: c.item.title, text: c.body, vocabulary: vocabulary)
                let written = try library.withAccess { _ in try Self.apply(result, to: c.url) }
                if written { summary.tagged.append(c.item.id) }
                attempts[c.item.id] = nil
                for t in result.tags where !vocabulary.contains(t) { vocabulary.append(t) }
            } catch TaggingError.missingAPIKey {
                summary.missingKey = true
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

    static func describe(_ error: Error) -> String {
        switch error {
        case TaggingError.api(let status, let message): return "API \(status): \(message)"
        case TaggingError.network(let m): return "network: \(m)"
        case TaggingError.malformedResponse: return "unreadable model response"
        case TaggingError.noTags: return "model returned no usable tags"
        default: return error.localizedDescription
        }
    }

    // MARK: File work (synchronous, runs inside library access)

    static func markdownFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func scan(_ folder: URL) -> (pending: [Candidate], vocabulary: [String]) {
        var vocab: [String] = [], seen = Set<String>(), pending: [Candidate] = []
        for url in markdownFiles(in: folder) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text) else { continue }
            for t in doc.item.tags where seen.insert(Tagger.canonical(t)).inserted { vocab.append(t) }
            if doc.item.tags.isEmpty { pending.append(Candidate(url: url, item: doc.item, body: doc.body)) }
        }
        return (pending, vocab)
    }

    /// Re-reads the file (it may have changed during the API call) and writes tags only if still untagged.
    static func apply(_ result: TagResult, to url: URL) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        var doc = try FrontmatterCodec.decode(text)
        guard doc.item.tags.isEmpty else { return false }
        doc.item.tags = result.tags
        NewTagFlag.write(result.newTags, to: &doc.item)
        try FrontmatterCodec.encode(doc).write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
