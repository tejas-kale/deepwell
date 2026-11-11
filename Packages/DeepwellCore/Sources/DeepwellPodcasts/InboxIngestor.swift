import Foundation
import DeepwellLibrary
import DeepwellCapture

/// The iOS app's capture ingestion (ticket 18): everything the Share Extension and the Safari Web Extension queued in
/// the app group's `CaptureInbox` becomes an item file in the library, written with `ItemFileWriter` (coordinated).
///
/// Order: extracted payloads (articles, YouTube with captions) first, then links, which need the network (podcast
/// lookup, YouTube oEmbed). A podcast or video without a published transcript is saved with `needs_transcript: true`
/// for the Mac; the phone never transcribes. `record` is called once for every file written, and only for those, so
/// the caller can hand exactly these names to `PhoneTagger.recordCapture(fileName:)` (CaptureLedger).
///
/// An inbox file is removed as soon as its item is written, so a second run finds nothing to write again. Callers
/// must not run two ingestions at once (the app keeps one in flight).
public struct InboxIngestor: Sendable {
    public let inbox: CaptureInbox
    let links: SharedLinkIngestor
    let unsupported: SharedLinkIngestor.UnsupportedLinks

    public init(inbox: CaptureInbox, http: HTTPClient = URLSessionHTTPClient(),
                unsupported: SharedLinkIngestor.UnsupportedLinks = .saveLinkOnly) {
        self.inbox = inbox
        self.links = SharedLinkIngestor(http: http)
        self.unsupported = unsupported
    }

    public struct Result: Equatable, Sendable {
        public var saved: [URL] = []
        public var failures: [String] = []   // user-facing; links that failed for a transient reason stay queued
        public var rejected = 0              // unreadable payloads, moved to `rejected/`
        public var deferred = 0              // library unavailable: left queued
        public var isEmpty: Bool { saved.isEmpty && failures.isEmpty && rejected == 0 && deferred == 0 }
    }

    public var hasPending: Bool { !inbox.pending().isEmpty }

    @discardableResult
    public func ingest(into library: LibraryFolderStore, record: @Sendable (String) async -> Void) async -> Result {
        var result = Result()
        let drained = inbox.drain(into: library)
        result.saved = drained.saved
        result.rejected = drained.rejected
        result.deferred = drained.deferred
        let outcome = await links.drain(inbox: inbox, into: library, unsupported: unsupported)
        result.saved += outcome.saved
        result.failures = outcome.failures
        for file in result.saved { await record(file.lastPathComponent) }
        return result
    }
}
