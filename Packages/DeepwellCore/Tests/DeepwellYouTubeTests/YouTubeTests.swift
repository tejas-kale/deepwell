import XCTest
import DeepwellModel
@testable import DeepwellYouTube

final class YouTubeTests: XCTestCase {
    func testVideoID() {
        XCTAssertEqual(YouTube.videoID(from: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5s")), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTube.videoID(from: URL(string: "https://youtu.be/dQw4w9WgXcQ")), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTube.videoID(from: URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")), "dQw4w9WgXcQ")
        XCTAssertNil(YouTube.videoID(from: URL(string: "https://www.youtube.com/")))
        XCTAssertNil(YouTube.videoID(from: URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")))
        XCTAssertNil(YouTube.videoID(from: URL(string: "https://www.youtube.com/watch?v=bad")))
        XCTAssertNil(YouTube.videoID(from: nil))
    }

    func testURLs() {
        XCTAssertEqual(YouTube.watchURL(id: "dQw4w9WgXcQ").absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(YouTube.watchURL(id: "dQw4w9WgXcQ", startSeconds: 65).absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=65s")
        let e = YouTube.embedURL(id: "dQw4w9WgXcQ", startSeconds: 31, autoplay: true).absoluteString
        XCTAssertTrue(e.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"))
        XCTAssertTrue(e.contains("start=31") && e.contains("autoplay=1"))
        XCTAssertFalse(YouTube.embedURL(id: "dQw4w9WgXcQ").absoluteString.contains("start="))
    }

    // Exact output of youtube.js buildTranscriptMarkdown for the fixture timedtext-en.json3.
    let jsBody = """
    [0:00](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=0s) Welcome to the show. Today we look at compilers

    [0:31](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=31s) First, the lexer. It's simple. Then the parser.

    [1:02:05](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3725s) Thanks for watching.
    """

    func testParsesExtensionTranscript() {
        let segs = TranscriptParser.parse(jsBody)
        XCTAssertEqual(segs.map(\.startSeconds), [0, 31, 3725])
        XCTAssertEqual(segs[1].text, "First, the lexer. It's simple. Then the parser.")
        XCTAssertEqual(segs.map(\.timestamp), ["0:00", "0:31", "1:02:05"])
    }

    func testPlaceholderAndGarbageYieldNoSegments() {
        XCTAssertTrue(TranscriptParser.parse("_No published captions were available for this video._").isEmpty)
        XCTAssertTrue(TranscriptParser.parse("").isEmpty)
        XCTAssertTrue(TranscriptParser.parse("[x](https://a.com) text").isEmpty)
    }

    func testNeedsTranscriptMarkerRoundTripsThroughFrontmatter() throws {
        var item = Item(type: .youtube, title: "T", durationMinutes: 5)
        XCTAssertFalse(item.needsTranscript)
        item.markNeedsTranscript()
        item.markNeedsTranscript() // idempotent
        let text = FrontmatterCodec.encode(ItemDocument(item: item, body: "placeholder"))
        XCTAssertEqual(text.components(separatedBy: "needs_transcript: true").count, 2)
        var back = try FrontmatterCodec.decode(text).item
        XCTAssertTrue(back.needsTranscript)
        back.clearNeedsTranscript()
        XCTAssertFalse(back.needsTranscript)
        XCTAssertFalse(FrontmatterCodec.encode(ItemDocument(item: back, body: "x")).contains("needs_transcript"))
    }
}
