import XCTest
import DeepwellModel
import DeepwellLibrary
import DeepwellCapture
import DeepwellTagging
@testable import DeepwellPodcasts

/// Ticket 18: the iOS app ingesting what its extensions queued. Paths mirror the phone: the app group's `Inbox/`
/// and the iCloud container's `Documents/` (resolved with `resolveContainer()`, which has no local fallback).
final class InboxIngestorTests: XCTestCase {
    private struct FakeContainer: UbiquityContainerResolving {
        let root: URL?
        func containerURL() -> URL? { root }
    }

    private var root: URL!
    private var groupInbox: URL { root.appendingPathComponent("group.com.tejaskale.deepwell/Inbox", isDirectory: true) }
    private var containerRoot: URL { root.appendingPathComponent("iCloud~com~tejaskale~deepwell", isDirectory: true) }
    private var documents: URL { containerRoot.appendingPathComponent("Documents", isDirectory: true) }
    private var ledger: CaptureLedger!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dw-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        let suite = "dw-ingest-\(UUID().uuidString)"
        ledger = CaptureLedger(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func phoneStore() -> LibraryFolderStore {
        let store = LibraryFolderStore(container: FakeContainer(root: containerRoot), localFallback: root.appendingPathComponent("unused"))
        XCTAssertEqual(store.resolveContainer(), .iCloud(documents))
        return store
    }

    private func ingestor(_ routes: [String: String] = [:]) -> InboxIngestor {
        InboxIngestor(inbox: CaptureInbox(directory: groupInbox), http: StubHTTP(routes: routes))
    }

    private func ingest(_ ing: InboxIngestor, _ store: LibraryFolderStore) async -> InboxIngestor.Result {
        let ledger = ledger!
        return await ing.ingest(into: store) { ledger.record($0) }
    }

    private func libraryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    }

    private func load(_ url: URL) throws -> ItemDocument {
        try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8))
    }

    private static let podcastRoutes = ["https://itunes.apple.com/lookup": Fixture.lookup,
                                        "https://feeds.example.com/slow.xml": Fixture.feedNoTranscript]

    func testArticlePayloadBecomesAnItemFileInTheContainer() async throws {
        let store = phoneStore()
        let ing = ingestor()
        try ing.inbox.enqueue(CapturePayload(url: "https://example.com/paid-post", title: "A Paid Post", author: "Writer",
                                             markdown: "# A Paid Post\n\nSubscriber-only words.", wordCount: 4,
                                             capturedAt: "2026-11-11T08:00:00Z"))
        let result = await ingest(ing, store)

        XCTAssertEqual(result.saved.count, 1)
        XCTAssertEqual(result.saved[0].deletingLastPathComponent().standardizedFileURL, documents.standardizedFileURL)
        XCTAssertTrue(result.saved[0].lastPathComponent.hasPrefix("2026-11-11-a-paid-post-"))
        let doc = try load(result.saved[0])
        XCTAssertEqual(doc.item.type, .article)
        XCTAssertEqual(doc.item.title, "A Paid Post")
        XCTAssertEqual(doc.item.author, "Writer")
        XCTAssertEqual(doc.item.wordCount, 4)
        XCTAssertTrue(doc.body.contains("Subscriber-only words."))
        XCTAssertTrue(ing.inbox.pending().isEmpty)
    }

    func testYouTubeAndPodcastWithoutPublishedTranscriptAreLeftForTheMac() async throws {
        let store = phoneStore()
        let ing = ingestor(Self.podcastRoutes.merging(["https://www.youtube.com/oembed": #"{"title":"A Talk","author_name":"A Channel"}"#]) { a, _ in a })
        try ing.inbox.enqueue(.link(URL(string: "https://youtu.be/dQw4w9WgXcQ")!))          // YouTube app share
        try ing.inbox.enqueue(.link(Fixture.apple))                                            // Apple Podcasts share
        // Safari (share sheet or extension) on a watch page with no captions: the JS sends needsTranscript.
        try ing.inbox.enqueue(CapturePayload(url: "https://www.youtube.com/watch?v=abcdefghijk", title: "No Captions",
                                             markdown: "_No published captions._", type: "youtube", durationMinutes: 12,
                                             needsTranscript: true, videoId: "abcdefghijk"))
        let result = await ingest(ing, store)

        XCTAssertEqual(result.saved.count, 3)
        XCTAssertEqual(result.failures, [])
        let docs = try result.saved.map(load)
        XCTAssertEqual(Set(docs.map(\.item.type)), [.youtube, .podcast])
        XCTAssertTrue(docs.allSatisfy(\.item.needsTranscript), "every item waits for the Mac's transcription")
        let text = try result.saved.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(text.allSatisfy { $0.contains("needs_transcript: true") })
        XCTAssertEqual(docs.first { $0.item.type == .podcast }?.item.audioURL?.absoluteString, "https://cdn.example.com/sleep.mp3?x=1")
    }

    func testRecordsIntoTheLedgerExactlyTheFilesItWrote() async throws {
        let store = phoneStore()
        // No Overcast route: that link fails (HTTP 404) and stays queued. No oEmbed route either, but a YouTube link is
        // still saved (title falls back to the URL).
        let ing = ingestor(Self.podcastRoutes)
        try ing.inbox.enqueue(CapturePayload(url: "https://example.com/a", title: "Article", markdown: "some words"))
        try ing.inbox.enqueue(.link(Fixture.apple))
        try ing.inbox.enqueue(.link(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        try ing.inbox.enqueue(.link(URL(string: "https://overcast.fm/+AbC123")!))
        try Data("not json".utf8).write(to: groupInbox.appendingPathComponent("0-broken.json"))
        let result = await ingest(ing, store)

        XCTAssertEqual(result.saved.count, 3)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(ledger.pending, Set(result.saved.map(\.lastPathComponent)))
        XCTAssertEqual(Set(libraryFiles()), ledger.pending, "the ledger names exactly the library's new files")
        XCTAssertEqual(ing.inbox.pendingLinks().count, 1, "the Overcast link is retried next time")
    }

    func testNothingIsIngestedTwice() async throws {
        let store = phoneStore()
        let ing = ingestor(Self.podcastRoutes)
        try ing.inbox.enqueue(CapturePayload(url: "https://example.com/a", title: "Article", markdown: "some words"))
        try ing.inbox.enqueue(.link(Fixture.apple))
        let first = await ingest(ing, store)
        XCTAssertEqual(first.saved.count, 2)
        let files = libraryFiles(), recorded = ledger.pending

        let second = await ingest(ing, store)
        XCTAssertTrue(second.isEmpty)
        XCTAssertFalse(ing.hasPending)
        XCTAssertEqual(libraryFiles(), files)
        XCTAssertEqual(ledger.pending, recorded)
    }

    func testOtherLinksAreSavedLinkOnlyWithTheShareSheetTitle() async throws {
        let store = phoneStore()
        let ing = ingestor()
        try ing.inbox.enqueue(.link(URL(string: "https://example.com/post")!, title: "Shared From Another App"))
        try ing.inbox.enqueue(.link(URL(string: "https://example.com/untitled")!))
        let result = await ingest(ing, store)

        XCTAssertEqual(result.saved.count, 2)
        let docs = try result.saved.map(load)
        XCTAssertEqual(Set(docs.map(\.item.title)), ["Shared From Another App", "https://example.com/untitled"])
        XCTAssertTrue(docs.allSatisfy { $0.item.type == .article && !$0.item.needsTranscript })
        XCTAssertTrue(docs.allSatisfy { $0.body.hasPrefix(CapturePayload.linkOnlyBody) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupInbox.appendingPathComponent("unsupported").path))
    }

    func testSignedOutLeavesEverythingQueuedAndRecordsNothing() async throws {
        let store = LibraryFolderStore(container: FakeContainer(root: nil), localFallback: root.appendingPathComponent("unused"))
        XCTAssertNil(store.resolveContainer())
        let ing = ingestor(Self.podcastRoutes)
        try ing.inbox.enqueue(CapturePayload(url: "https://example.com/a", title: "Article", markdown: "some words"))
        try ing.inbox.enqueue(.link(Fixture.apple))
        let result = await ingest(ing, store)

        XCTAssertEqual(result.saved, [])
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(ing.inbox.pending().count, 2)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path), "no local fallback on iOS")
    }

    func testMacStillParksUnsupportedLinks() async throws {
        let store = phoneStore()
        let inbox = CaptureInbox(directory: groupInbox)
        try inbox.enqueue(.link(URL(string: "https://example.com/post")!))
        let outcome = await SharedLinkIngestor(http: StubHTTP(routes: [:])).drain(inbox: inbox, into: store)
        XCTAssertEqual(outcome.saved, [])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupInbox.appendingPathComponent("unsupported").path))
    }
}
