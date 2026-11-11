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
        public var skippedClaimed = 0        // another device holds a live claim (ticket 20)
        public var missingKey = false
    }

    private let library: LibraryAccessing
    private let model: IssueSplittingModel
    private let keys: APIKeyStore
    private let now: @Sendable () -> Date
    private let baseDelay: TimeInterval
    private let maxAttempts: Int
    /// This device's name for claims (`ProcessingClaim`); nil: no claims (single-device tests).
    private let device: String?
    private var attempts: [String: (count: Int, next: Date)] = [:]
    private var running = false

    public init(library: LibraryAccessing, model: IssueSplittingModel, keys: APIKeyStore,
                baseDelay: TimeInterval = 30, maxAttempts: Int = 5, device: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library; self.model = model; self.keys = keys; self.device = device
        self.baseDelay = baseDelay; self.maxAttempts = maxAttempts; self.now = now
    }

    /// Issue ids in `issues/` that have no article item yet.
    nonisolated static func pending(in folder: URL) -> [IssueStore.Ref] {
        let done = IssueStore.splitIDs(inLibrary: folder)
        return IssueStore.all(in: folder).filter { !done.contains($0.id) }
    }

    /// Markers whose issue already has articles (split on another Mac, or the marker arrived after the split).
    nonisolated static func staleMarkers(in folder: URL) -> [String] {
        let done = IssueStore.splitIDs(inLibrary: folder)
        return PendingIssue.markerIDs(inLibrary: folder).filter(done.contains)
    }

    @discardableResult
    public func processPending() async -> RunSummary {
        var summary = RunSummary()
        guard !running else { return summary }
        running = true; defer { running = false }

        let refs: [IssueStore.Ref]
        do {
            refs = try library.withAccess { folder in
                for id in Self.staleMarkers(in: folder) { PendingIssue.remove(issueID: id, inLibrary: folder) }
                return Self.pending(in: folder)
            }
        } catch { return summary }

        for ref in refs {
            if let a = attempts[ref.id], a.next > now() { summary.skippedBackoff += 1; continue }
            guard claim(ref) else { summary.skippedClaimed += 1; continue }
            var done = false
            defer { if done { finish(ref) } else { release(ref) } }
            do {
                let issue = try library.withAccess { _ in try IssueExtractor.extract(ref.url) }
                guard issue.hasText else {
                    try write(ref, issue: issue, spans: [Self.wholeIssue(issue)], noText: true)
                    summary.fallbacks += 1; summary.imported.append(ref.id); summary.articles += 1
                    done = true
                    continue
                }
                guard keys.load() != nil else { summary.missingKey = true; break }
                let spans = try await model.split(issueTitle: issue.title, units: issue.units)
                try write(ref, issue: issue, spans: spans, noText: false)
                attempts[ref.id] = nil
                summary.imported.append(ref.id); summary.articles += spans.count
                done = true
            } catch TaggingError.missingAPIKey {
                summary.missingKey = true; break
            } catch {
                let n = (attempts[ref.id]?.count ?? 0) + 1
                if n >= maxAttempts, let issue = try? library.withAccess({ _ in try IssueExtractor.extract(ref.url) }) {
                    // The model keeps failing: don't leave the issue unreadable. Keep it as one item.
                    if (try? write(ref, issue: issue, spans: [Self.wholeIssue(issue)], noText: false)) != nil {
                        attempts[ref.id] = nil
                        summary.fallbacks += 1; summary.imported.append(ref.id); summary.articles += 1
                        done = true
                        continue
                    }
                }
                summary.failed += 1
                attempts[ref.id] = (n, now().addingTimeInterval(min(baseDelay * pow(2, Double(n - 1)), 3600)))
            }
        }
        return summary
    }

    // MARK: - Claims (ticket 20)

    /// Writes this device's claim into the issue's marker (creating one for an issue imported on a Mac). False if
    /// another device holds a live claim. Without a device name (tests) every issue is fair game.
    private func claim(_ ref: IssueStore.Ref) -> Bool {
        guard let device else { return true }
        let at = now()
        return (try? library.withAccess { folder -> Bool in
            var marker = PendingIssue.read(issueID: ref.id, inLibrary: folder)
                ?? PendingIssue(issueID: ref.id, file: ref.url.lastPathComponent,
                                title: ref.url.deletingPathExtension().lastPathComponent)
            if let c = marker.claim, c.blocks(device, at: at) { return false }
            marker.claim = ProcessingClaim(device: device, at: at)
            try marker.write(inLibrary: folder)
            return true
        }) ?? false
    }

    /// Split: the marker has done its job.
    private func finish(_ ref: IssueStore.Ref) {
        guard device != nil else { return }
        try? library.withAccess { PendingIssue.remove(issueID: ref.id, inLibrary: $0) }
    }

    /// Not split this time (no key, model error): drop our claim so another Mac can try; the marker stays.
    private func release(_ ref: IssueStore.Ref) {
        guard let device else { return }
        try? library.withAccess { folder in
            guard var marker = PendingIssue.read(issueID: ref.id, inLibrary: folder),
                  marker.claim?.device == ProcessingClaim(device: device, at: now()).device else { return }
            marker.claim = nil
            try marker.write(inLibrary: folder)
        }
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
