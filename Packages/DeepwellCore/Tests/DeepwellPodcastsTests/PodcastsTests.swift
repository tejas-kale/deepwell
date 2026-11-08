import XCTest
import DeepwellModel
import DeepwellLibrary
import DeepwellCapture
import DeepwellTranscription
@testable import DeepwellPodcasts

// Fixtures are hand-written in the shape of the real iTunes Lookup API, Podcasting 2.0 RSS and Overcast pages;
// they were not recorded from the live services.
private struct StubHTTP: HTTPClient {
    var routes: [String: String]
    func get(_ url: URL) async throws -> Data {
        guard let body = routes.first(where: { url.absoluteString.hasPrefix($0.key) })?.value else { throw PodcastError.http(404) }
        return Data(body.utf8)
    }
}

private enum Fixture {
    static let lookup = """
    {"resultCount":1,"results":[{"wrapperType":"podcastEpisode","kind":"podcast-episode","trackName":"The Deep Dive: Sleep",
     "collectionName":"Slow Science","artistName":"Slow Science Co","episodeGuid":"guid-42",
     "episodeUrl":"https://cdn.example.com/fallback.mp3","feedUrl":"https://feeds.example.com/slow.xml","trackTimeMillis":3723000}]}
    """
    static let feed = """
    <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
    <channel><title>Slow Science</title>
      <item><title>Other</title><guid>guid-1</guid><enclosure url="https://cdn.example.com/other.mp3" type="audio/mpeg"/></item>
      <item><title><![CDATA[The Deep Dive: Sleep]]></title><guid isPermaLink="false">guid-42</guid>
        <enclosure url="https://cdn.example.com/sleep.mp3?x=1" length="1" type="audio/mpeg"/>
        <itunes:duration>1:02:03</itunes:duration>
        <podcast:transcript url="https://cdn.example.com/sleep.vtt" type="text/vtt"/>
      </item></channel></rss>
    """
    static let feedNoTranscript = feed.replacingOccurrences(of: "<podcast:transcript url=\"https://cdn.example.com/sleep.vtt\" type=\"text/vtt\"/>", with: "")
    static let vtt = """
    WEBVTT

    00:00:01.000 --> 00:00:04.000
    <v Host>Welcome to the show.

    00:00:40.500 --> 00:00:44.000
    Today: sleep.
    """
    static let overcast = """
    <html><head><meta property="og:title" content="Why We Sleep &amp; Dream — Slow Science">
    <meta property="og:audio" content="https://cdn.example.com/ov.mp3#t=0"></head>
    <body><audio id="audioplayer"><source src="https://cdn.example.com/ov.mp3#t=0" type="audio/mpeg"></audio></body></html>
    """
    static let apple = URL(string: "https://podcasts.apple.com/us/podcast/the-deep-dive-sleep/id111222333?i=1000555666777")!
}

final class PodcastsTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(SharedLink.classify(Fixture.apple), .appleEpisode(showID: "111222333", episodeID: "1000555666777"))
        XCTAssertEqual(SharedLink.classify(URL(string: "https://podcasts.apple.com/us/podcast/x/id111222333")!), .appleShow(showID: "111222333"))
        XCTAssertEqual(SharedLink.classify(URL(string: "https://overcast.fm/+AbC123")!), .overcast(URL(string: "https://overcast.fm/+AbC123")!))
        XCTAssertEqual(SharedLink.classify(URL(string: "https://youtu.be/dQw4w9WgXcQ")!), .youtube(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(SharedLink.classify(URL(string: "https://example.com/post")!), .unsupported)
        XCTAssertEqual(SharedLink.firstURL(in: "Listen to this\nhttps://overcast.fm/+AbC123 now")?.absoluteString, "https://overcast.fm/+AbC123")
    }

    func testRSSParsing() throws {
        let feed = try RSSParser.parse(Data(Fixture.feed.utf8))
        XCTAssertEqual(feed.title, "Slow Science")
        XCTAssertEqual(feed.episodes.count, 2)
        XCTAssertEqual(feed.episodes[1].title, "The Deep Dive: Sleep")
        XCTAssertEqual(feed.episodes[1].durationSeconds, 3723)
        XCTAssertEqual(feed.episodes[1].transcriptType, "text/vtt")
    }

    func testAppleResolvesToEnclosureViaFeed() async throws {
        let http = StubHTTP(routes: ["https://itunes.apple.com/lookup": Fixture.lookup, "https://feeds.example.com/slow.xml": Fixture.feed])
        let ep = try await PodcastResolver(http: http).resolve(SharedLink.classify(Fixture.apple), sourceURL: Fixture.apple)
        XCTAssertEqual(ep.audioURL.absoluteString, "https://cdn.example.com/sleep.mp3?x=1")   // feed enclosure beats lookup episodeUrl
        XCTAssertEqual(ep.title, "The Deep Dive: Sleep")
        XCTAssertEqual(ep.show, "Slow Science")
        XCTAssertEqual(ep.durationMinutes, 62)
        XCTAssertEqual(ep.transcriptURL?.absoluteString, "https://cdn.example.com/sleep.vtt")
    }

    func testAppleFallsBackToLookupEpisodeUrlWhenFeedFails() async throws {
        let http = StubHTTP(routes: ["https://itunes.apple.com/lookup": Fixture.lookup])
        let ep = try await PodcastResolver(http: http).resolve(SharedLink.classify(Fixture.apple), sourceURL: Fixture.apple)
        XCTAssertEqual(ep.audioURL.absoluteString, "https://cdn.example.com/fallback.mp3")
        XCTAssertNil(ep.transcriptURL)
    }

    func testAppleShowLinkAndMissingEpisodeAreErrors() async {
        let show = URL(string: "https://podcasts.apple.com/us/podcast/x/id111222333")!
        let r = PodcastResolver(http: StubHTTP(routes: ["https://itunes.apple.com/lookup": #"{"resultCount":0,"results":[]}"#]))
        do { _ = try await r.resolve(SharedLink.classify(show), sourceURL: show); XCTFail() } catch { XCTAssertEqual(error as? PodcastError, .notAnEpisode) }
        do { _ = try await r.resolve(SharedLink.classify(Fixture.apple), sourceURL: Fixture.apple); XCTFail() } catch { XCTAssert(error is PodcastError) }
    }

    func testOvercastResolvesAudioAndMetadata() async throws {
        let url = URL(string: "https://overcast.fm/+AbC123")!
        let ep = try await PodcastResolver(http: StubHTTP(routes: ["https://overcast.fm/": Fixture.overcast])).resolve(SharedLink.classify(url), sourceURL: url)
        XCTAssertEqual(ep.audioURL.absoluteString, "https://cdn.example.com/ov.mp3")
        XCTAssertEqual(ep.title, "Why We Sleep & Dream")
        XCTAssertEqual(ep.show, "Slow Science")
    }

    func testTranscriptFileParsing() {
        let vtt = TranscriptFile.parse(Data(Fixture.vtt.utf8), type: "text/vtt")
        XCTAssertEqual(vtt, [TimedWord(start: 1, text: "Welcome to the show."), TimedWord(start: 40.5, text: "Today: sleep.")])
        let srt = TranscriptFile.parse(Data("1\n00:01:05,000 --> 00:01:07,000\nHi there\n".utf8), type: "application/x-subrip")
        XCTAssertEqual(srt, [TimedWord(start: 65, text: "Hi there")])
        let json = TranscriptFile.parse(Data(#"{"segments":[{"startTime":3.5,"body":" Hello "}]}"#.utf8), type: "application/json")
        XCTAssertEqual(json, [TimedWord(start: 3.5, text: "Hello")])
        XCTAssertTrue(TranscriptFile.parse(Data("just text".utf8), type: "text/plain").isEmpty)
    }

    func testPodcastItemWithPublishedTranscriptIsNotQueued() async throws {
        let http = StubHTTP(routes: ["https://itunes.apple.com/lookup": Fixture.lookup, "https://feeds.example.com/slow.xml": Fixture.feed,
                                     "https://cdn.example.com/sleep.vtt": Fixture.vtt])
        let doc = try await SharedLinkIngestor(http: http).document(for: Fixture.apple)
        XCTAssertEqual(doc.item.type, .podcast)
        XCTAssertEqual(doc.item.author, "Slow Science")
        XCTAssertEqual(doc.item.durationMinutes, 62)
        XCTAssertEqual(doc.item.sourceURL, Fixture.apple)
        XCTAssertFalse(doc.item.needsTranscript)
        XCTAssertEqual(doc.item.audioURL?.absoluteString, "https://cdn.example.com/sleep.mp3?x=1")
        XCTAssertTrue(doc.body.contains("Welcome to the show."))
        XCTAssertEqual(TranscriptParserShim.count(doc.body), 2)
    }

    func testPodcastWithoutTranscriptIsMarkedAndSurvivesRoundTrip() async throws {
        let http = StubHTTP(routes: ["https://itunes.apple.com/lookup": Fixture.lookup, "https://feeds.example.com/slow.xml": Fixture.feedNoTranscript])
        let doc = try await SharedLinkIngestor(http: http).document(for: Fixture.apple)
        XCTAssertTrue(doc.item.needsTranscript)
        let back = try FrontmatterCodec.decode(FrontmatterCodec.encode(doc))
        XCTAssertTrue(back.item.needsTranscript)
        XCTAssertEqual(back.item.audioURL?.absoluteString, "https://cdn.example.com/sleep.mp3?x=1")
        XCTAssertEqual(back.item.type, .podcast)
        let audio = try await PodcastAudioResolver(http: StubHTTP(routes: [:])).audioURL(for: back.item)
        XCTAssertEqual(audio.absoluteString, "https://cdn.example.com/sleep.mp3?x=1")
    }

    func testYouTubeLinkFollowsNoCaptionsPath() async throws {
        let http = StubHTTP(routes: ["https://www.youtube.com/oembed": #"{"title":"A Talk","author_name":"A Channel"}"#])
        let doc = try await SharedLinkIngestor(http: http).document(for: URL(string: "https://youtu.be/dQw4w9WgXcQ")!)
        XCTAssertEqual(doc.item.type, .youtube)
        XCTAssertEqual(doc.item.title, "A Talk")
        XCTAssertEqual(doc.item.author, "A Channel")
        XCTAssertEqual(doc.item.sourceURL?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertTrue(doc.item.needsTranscript)
    }

    func testDrainSavesPodcastAndParksUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
        let libDir = root.appendingPathComponent("lib"), inboxDir = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemStorage()
        let store = LibraryFolderStore(storage: storage)
        try store.choose(libDir)

        let inbox = CaptureInbox(directory: inboxDir)
        try inbox.enqueue(.link(Fixture.apple))
        try inbox.enqueue(.link(URL(string: "https://example.com/post")!))
        try inbox.enqueue(CapturePayload(url: "https://example.com/a", title: "Art", markdown: "body words here"))

        // Plain drain must leave links alone and still save the article.
        XCTAssertEqual(inbox.drain(into: store).saved.count, 1)
        XCTAssertEqual(inbox.pendingLinks().count, 2)

        let http = StubHTTP(routes: ["https://itunes.apple.com/lookup": Fixture.lookup, "https://feeds.example.com/slow.xml": Fixture.feedNoTranscript])
        let outcome = await SharedLinkIngestor(http: http).drain(inbox: inbox, into: store)
        XCTAssertEqual(outcome.saved.count, 1)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(inbox.pendingLinks().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inboxDir.appendingPathComponent("unsupported").path))
        let text = try String(contentsOf: outcome.saved[0], encoding: .utf8)
        XCTAssertTrue(text.contains("type: podcast"))
    }
}

private final class MemStorage: BookmarkStorage, @unchecked Sendable {
    var data: Data?
    func load() -> Data? { data }
    func save(_ d: Data?) { data = d }
}

import DeepwellYouTube
private enum TranscriptParserShim { static func count(_ body: String) -> Int { TranscriptParser.parse(body).count } }
