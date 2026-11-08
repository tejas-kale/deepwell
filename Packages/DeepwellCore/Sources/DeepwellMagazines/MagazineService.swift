import Foundation
import DeepwellModel
import DeepwellLibrary
import DeepwellTagging

/// Turns stored issues into `magazine-article` items. The queue is derived from the library: an original in
/// `issues/` with no item carrying its `issue_id` is pending, so a missing key, offline start or crash just
/// leaves it for the next pass. Capture (staging the original) never depends on this.
/// Articles are written untagged; `TaggingService` (ticket 03) tags them on its next pass.
public actor MagazineService {
    public struct RunSummary: Equatable, Sendable {
        public var imported: [String] = []   // issue ids split into articles
        public var articles = 0
        public var fallbacks = 0             // issues kept as one whole-issue item
        public var failed = 0
        public var skippedBackoff = 0
        public var missingKey = false
    }

    private let library: LibraryAccessing
    private let model: IssueSplittingModel
    private let keys: APIKeyStore
    private let now: @Sendable () -> Date
    private let baseDelay: TimeInterval
    private let maxAttempts: Int
    private var attempts: [String: (count: Int, next: Date)] = [:]
    private var running = false

    public init(library: LibraryAccessing, model: IssueSplittingModel, keys: APIKeyStore,
                baseDelay: TimeInterval = 30, maxAttempts: Int = 5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library; self.model = model; self.keys = keys
        self.baseDelay = baseDelay; self.maxAttempts = maxAttempts; self.now = now
    }

    /// Issue ids in `issues/` that have no article item yet.
    nonisolated static func pending(in folder: URL) -> [IssueStore.Ref] {
        var done = Set<String>()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "md" {
            if let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text),
               let id = doc.item.issueID { done.insert(id) }
        }
        return IssueStore.all(in: folder).filter { !done.contains($0.id) }
    }

    @discardableResult
    public func processPending() async -> RunSummary {
        var summary = RunSummary()
        guard !running else { return summary }
        running = true; defer { running = false }

        let refs: [IssueStore.Ref]
        do { refs = try library.withAccess { Self.pending(in: $0) } } catch { return summary }

        for ref in refs {
            if let a = attempts[ref.id], a.next > now() { summary.skippedBackoff += 1; continue }
            do {
                let issue = try library.withAccess { _ in try IssueExtractor.extract(ref.url) }
                guard issue.hasText else {
                    try write(ref, issue: issue, spans: [Self.wholeIssue(issue)], noText: true)
                    summary.fallbacks += 1; summary.imported.append(ref.id); summary.articles += 1
                    continue
                }
                guard keys.load() != nil else { summary.missingKey = true; break }
                let spans = try await model.split(issueTitle: issue.title, units: issue.units)
                try write(ref, issue: issue, spans: spans, noText: false)
                attempts[ref.id] = nil
                summary.imported.append(ref.id); summary.articles += spans.count
            } catch TaggingError.missingAPIKey {
                summary.missingKey = true; break
            } catch {
                let n = (attempts[ref.id]?.count ?? 0) + 1
                if n >= maxAttempts, let issue = try? library.withAccess({ _ in try IssueExtractor.extract(ref.url) }) {
                    // The model keeps failing: don't leave the issue unreadable. Keep it as one item.
                    if (try? write(ref, issue: issue, spans: [Self.wholeIssue(issue)], noText: false)) != nil {
                        attempts[ref.id] = nil
                        summary.fallbacks += 1; summary.imported.append(ref.id); summary.articles += 1
                        continue
                    }
                }
                summary.failed += 1
                attempts[ref.id] = (n, now().addingTimeInterval(min(baseDelay * pow(2, Double(n - 1)), 3600)))
            }
        }
        return summary
    }

    static func wholeIssue(_ issue: ExtractedIssue) -> ArticleSpan {
        ArticleSpan(title: issue.title, start: 0, end: max(issue.units.count - 1, 0))
    }

    private func write(_ ref: IssueStore.Ref, issue: ExtractedIssue, spans: [ArticleSpan], noText: Bool) throws {
        let capturedAt = now()
        try library.withAccess { folder in
            // Re-check under access: another pass may have written these already.
            guard Self.pending(in: folder).contains(where: { $0.id == ref.id }) else { return }
            for s in spans {
                let body = noText
                    ? "_No text could be extracted from this issue (it may be scanned). Open the original to read it._"
                    : issue.units[s.start...s.end].joined(separator: "\n\n")
                var item = Item(type: .magazineArticle, title: s.title, author: s.author, capturedAt: capturedAt,
                                wordCount: body.split(whereSeparator: { $0.isWhitespace }).count, issueID: ref.id)
                IssuePosition.write(start: s.start, end: s.end, to: &item)
                try ItemFileWriter.write(ItemDocument(item: item, body: body), into: folder)
            }
        }
    }
}
