import XCTest
import DeepwellModel
@testable import DeepwellCapture

final class YouTubeCaptureTests: XCTestCase {
    // Shape emitted by youtube.js buildPayload (null optionals included).
    private func decode(_ json: String) throws -> CapturePayload {
        try JSONDecoder().decode(CapturePayload.self, from: Data(json.utf8))
    }

    func testYouTubeWithCaptions() throws {
        let p = try decode(#"""
        {"type":"youtube","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","title":"How Compilers Work","author":"Code Channel",
         "siteName":"YouTube","excerpt":"","markdown":"[0:00](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=0s) Hi","wordCount":1,
         "durationMinutes":31,"videoId":"dQw4w9WgXcQ","needsTranscript":false,"captionKind":"manual","captionLang":"en",
         "capturedAt":"2027-01-15T08:00:00.000Z"}
        """#)
        let doc = try p.validated().makeDocument(id: "id1")
        XCTAssertEqual(doc.item.type, .youtube)
        XCTAssertEqual(doc.item.durationMinutes, 31)
        XCTAssertNil(doc.item.wordCount)
        XCTAssertFalse(doc.item.needsTranscript)
        let text = FrontmatterCodec.encode(doc)
        XCTAssertTrue(text.contains("type: youtube"))
        XCTAssertTrue(text.contains("duration_minutes: 31"))
        XCTAssertFalse(text.contains("word_count"))
        XCTAssertFalse(text.contains("needs_transcript"))
    }

    func testYouTubeWithoutCaptionsGetsMarker() throws {
        let p = try decode(#"""
        {"type":"youtube","url":"https://www.youtube.com/watch?v=zzzzzzzzzzz","title":"Silent","author":"Q","markdown":"_No captions_",
         "wordCount":0,"durationMinutes":61,"needsTranscript":true,"captionKind":null,"captionLang":null}
        """#)
        let doc = try p.validated().makeDocument(id: "id2")
        XCTAssertTrue(doc.item.needsTranscript)
        let text = FrontmatterCodec.encode(doc)
        XCTAssertTrue(text.contains("needs_transcript: true"))
        XCTAssertTrue(text.contains("duration_minutes: 61"))
        XCTAssertTrue(try FrontmatterCodec.decode(text).item.needsTranscript)
    }

    func testArticlePayloadsUnchangedAndUnknownTypeRejected() throws {
        let article = try decode(#"{"url":"https://a.com/x","title":"T","markdown":"m","wordCount":1}"#)
        XCTAssertEqual(article.makeDocument().item.type, .article)
        XCTAssertEqual(article.makeDocument().item.wordCount, 1)
        XCTAssertThrowsError(try decode(#"{"type":"podcast","url":"https://a.com/x","title":"T","markdown":"m"}"#).validated())
        // an article payload must never pick up the marker
        let sneaky = CapturePayload(url: "https://a.com/x", title: "T", markdown: "m", needsTranscript: true)
        XCTAssertFalse(sneaky.makeDocument().item.needsTranscript)
    }
}
