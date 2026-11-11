import XCTest
import DeepwellModel
import DeepwellTagging
import DeepwellTranscription
@testable import DeepwellNarration

/// Records speech requests and answers each with fake MP3 bytes, or with the next queued status.
final class SpeechStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String: Any]] = []
    private var _headers: [[String: String]] = []
    /// Status codes to answer with, in order, before succeeding.
    var failures: [(Int, String)] = []
    var contentType = "audio/mpeg"

    var requests: [[String: Any]] { lock.withLock { _requests } }
    var inputs: [String] { requests.map { $0["input"] as! String } }
    var headers: [[String: String]] { lock.withLock { _headers } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let (code, body): (Int, String) = lock.withLock {
            _requests.append(json)
            _headers.append(request.allHTTPHeaderFields ?? [:])
            return failures.isEmpty ? (200, "MP3:" + (json["input"] as! String)) : failures.removeFirst()
        }
        let type = code == 200 ? contentType : "application/json"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                                 headerFields: ["Content-Type": type])!)
    }
}

/// "Hears" each chunk's audio as the words it was asked to say, one every half second, with optional edits.
final class EchoTranscriber: Transcriber, @unchecked Sendable {
    var edit: ([String]) -> [String] = { $0 }
    /// Edits after timing: each word keeps its true time (index × 0.5 s), so a dropped stretch leaves a gap.
    var editTimed: ([TimedWord]) -> [TimedWord] = { $0 }
    var error: Error?
    func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        if let error { throw error }
        let text = String(decoding: try Data(contentsOf: audioFile), as: UTF8.self).replacingOccurrences(of: "MP3:", with: "")
        let words = edit(text.split(whereSeparator: \.isWhitespace).map(String.init))
        return editTimed(words.enumerated().map { TimedWord(start: Double($0.offset) * 0.5, text: $0.element) })
    }
}

@MainActor
final class NarrationSessionTests: XCTestCase {
    var library: URL!
    var itemFile: URL!
    let keys = InMemoryAPIKeyStore(key: "sk-or-secret")

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        itemFile = library.appendingPathComponent("2026-11-11-essay-abcd1234.md")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: library) }

    let item = Item(type: .article, title: "On Wells", author: "Ada Lovelace")

    let body = """
    # Digging deep

    The well was old. It had been dug by hand in 1890. Nobody knew how deep it went.

    ```
    let x = 1
    ```

    ![A well](https://example.com/well.png)

    Photo by someone.

    - Rope and bucket
    - A **heavy** stone lid

    > Water finds its level.

    Read more at https://example.com/wells today.
    """

    func session(body: String? = nil, settings: NarrationSettings = NarrationSettings(), pronunciations: [String: String] = [:],
                 transport: SpeechStub, transcriber: Transcriber? = nil, duration: TimeInterval = 10) -> NarrationSession {
        NarrationSession(item: item, body: body ?? self.body, folder: NarrationSession.folder(forItemFile: itemFile),
                         settings: settings, pronunciations: pronunciations, keys: keys, transport: transport,
                         transcriber: transcriber, durationOf: { _ in duration }, retryDelays: [0, 0, 0])
    }

    private var folder: URL { NarrationSession.folder(forItemFile: itemFile) }
    private func files() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
    private func manifest() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
    }

    private func prepareAll(_ s: NarrationSession) async throws {
        for i in s.script.chunks.indices { _ = try await s.prepare(chunk: i) }
    }

    // MARK: Script

    func testScriptSpeaksIntroAndProseAndSkipsCodeImagesCaptionsAndURLs() async throws {
        let stub = SpeechStub()
        let s = session(transport: stub)
        await s.open()
        try await prepareAll(s)
        let spoken = stub.inputs.joined(separator: "\n\n")
        XCTAssertTrue(spoken.hasPrefix("On Wells. By Ada Lovelace."), spoken)
        XCTAssertTrue(spoken.contains("Digging deep."), "headings are spoken with a full stop")
        XCTAssertTrue(spoken.contains("Rope and bucket."), "list items end as sentences")
        XCTAssertTrue(spoken.contains("A heavy stone lid."), "inline Markdown is spoken as displayed")
        XCTAssertTrue(spoken.contains("Water finds its level."))
        XCTAssertFalse(spoken.contains("let x"), "code is skipped")
        XCTAssertFalse(spoken.contains("Photo by someone"), "captions are skipped")
        XCTAssertFalse(spoken.contains("example.com"), "URLs are not read out")
        XCTAssertTrue(spoken.contains("Read more at today."))
    }

    func testWordsPointAtTheTextTheReaderShows() {
        let s = session(transport: SpeechStub())
        let blocks = ArticleBlocks.blocks(for: body)
        let located = s.script.words.filter { $0.location != nil }
        XCTAssertFalse(located.isEmpty)
        for w in located {
            let loc = w.location!
            let plain = Array(ArticleBlocks.plainText(blocks[loc.block].inlineMarkdown!))
            XCTAssertEqual(String(plain[loc.range]), w.written)
        }
        XCTAssertTrue(s.script.words.prefix(5).allSatisfy { $0.location == nil }, "intro words are not in the body")
        let heavy = located.first { $0.written == "heavy" }!
        XCTAssertEqual(heavy.spoken, "heavy", "bold markers are not part of the word")
    }

    func testSentencesKeepTitlesAndInitialsWithTheirNames() {
        let s = session(body: "Dr. Smith met J. Doe. They talked.", transport: SpeechStub())
        let sentences = s.script.sentences.map { r in s.script.words[r].map(\.written).joined(separator: " ") }
        XCTAssertEqual(Array(sentences.suffix(2)), ["Dr. Smith met J. Doe.", "They talked."])
    }

    func testPronunciationsChangeOnlyTheSpokenText() async throws {
        let stub = SpeechStub()
        let s = session(body: "I read Beehiiv's posts on GitHub Pages daily.",
                        pronunciations: ["beehiiv": "beehive", "GitHub Pages": "git hub pages"], transport: stub)
        await s.open()
        try await prepareAll(s)
        XCTAssertTrue(stub.inputs.joined().contains("I read beehive's posts on git hub pages daily."), stub.inputs.joined())
        XCTAssertTrue(s.script.words.contains { $0.written == "Beehiiv's" })
        XCTAssertTrue(s.script.words.contains { $0.written == "Pages" && $0.spoken.isEmpty })
    }

    func testPronunciationFileInTheLibraryOverridesTheBundledMap() throws {
        let store = PronunciationStore(libraryFolder: library)
        XCTAssertEqual(PronunciationStore.bundled["beehiiv"], "beehive", "readcast's map is bundled")
        try store.save(["Beehiiv": "bee hive", "Nguyen": "win", "a: b": "quoted \"key\""])
        XCTAssertEqual(store.load(), ["Beehiiv": "bee hive", "Nguyen": "win", "a: b": "quoted \"key\""], "round-trips through YAML")
        let merged = store.merged()
        XCTAssertEqual(merged["Beehiiv"], "bee hive")
        XCTAssertNil(merged["beehiiv"], "keys merge case-insensitively")
        let s = session(body: "Beehiiv by Nguyen.", pronunciations: merged, transport: SpeechStub())
        XCTAssertTrue(s.script.chunks.map(\.text).joined().contains("bee hive by win."))
    }

    func testReadsReadcastStyleYAML() {
        let parsed = PronunciationStore.parse("""
        # comment
        beehiiv: beehive
        'O''Reilly': oh riley   # trailing comment
        "Nginx": "engine x"
        """)
        XCTAssertEqual(parsed, ["beehiiv": "beehive", "O'Reilly": "oh riley", "Nginx": "engine x"])
    }

    // MARK: Chunking

    func testFirstChunkIsShortAndLaterChunksRespectLimits() {
        let para = (1...60).map { "Sentence number \($0) is here." }.joined(separator: " ")   // ~300 words
        let long = Array(repeating: para, count: 3).joined(separator: "\n\n")
        let s = session(body: long, transport: SpeechStub())
        let chunks = s.script.chunks
        let first = s.script.words[chunks[0].words].count
        XCTAssertLessThanOrEqual(first, 20, "playback starts after a sentence or two")
        XCTAssertGreaterThan(chunks.count, 3)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.split(separator: " ").count, 350)
            XCTAssertLessThanOrEqual(c.text.count, 1900)
        }
        // Chunks tile the script.
        XCTAssertEqual(chunks.first!.words.lowerBound, 0)
        XCTAssertEqual(chunks.last!.words.upperBound, s.script.words.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.words.upperBound, b.words.lowerBound) }
    }

    // MARK: Generating and saving

    func testPrepareRequestsOpenRouterSpeechAndSavesTheChunk() async throws {
        let stub = SpeechStub()
        let s = session(transport: stub)
        await s.open()
        XCTAssertEqual(s.statuses.first, .missing)
        let p = try await s.prepare(chunk: 0)
        let req = stub.requests[0]
        XCTAssertEqual(req["model"] as? String, "microsoft/mai-voice-2-flash")
        XCTAssertEqual(req["voice"] as? String, "en-US-Harper:MAI-Voice-2")
        XCTAssertEqual(req["response_format"] as? String, "mp3")
        XCTAssertEqual(stub.headers[0]["Authorization"], "Bearer sk-or-secret")
        XCTAssertEqual(s.statuses[0], .ready)
        XCTAssertEqual(try String(contentsOf: p.file, encoding: .utf8), "MP3:" + s.script.chunks[0].text)
        XCTAssertEqual(p.starts.count, s.script.chunks[0].words.count)
        XCTAssertTrue(files().contains("manifest.json"))
        XCTAssertTrue(files().contains(p.file.lastPathComponent))
        XCTAssertEqual(p.file.deletingLastPathComponent().lastPathComponent, "2026-11-11-essay-abcd1234.narration")
    }

    func testConcurrentPreparesOfOneChunkShareOneRequest() async throws {
        let stub = SpeechStub()
        let s = session(transport: stub)
        await s.open()
        async let a = s.prepare(chunk: 0)
        async let b = s.prepare(chunk: 0)
        _ = try await (a, b)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testASecondSessionReusesSavedAudioWithoutRequests() async throws {
        let first = SpeechStub()
        let s1 = session(transport: first)
        await s1.open()
        try await prepareAll(s1)
        let second = SpeechStub()
        let s2 = session(transport: second)
        await s2.open()
        XCTAssertTrue(s2.statuses.allSatisfy { $0 == .ready })
        try await prepareAll(s2)
        XCTAssertTrue(second.requests.isEmpty)
    }

    func testEditingOneParagraphRegeneratesOnlyThatChunkAndDeletesOrphans() async throws {
        // Paragraph-sized blocks (over the ~120-word packing target), so each is its own chunk.
        let paras = (1...4).map { n in (1...32).map { "Paragraph \(n) word \($0)." }.joined(separator: " ") }
        let rewritten = (1...32).map { "Rewritten sentence \($0) here." }.joined(separator: " ")
        let s1 = session(body: paras.joined(separator: "\n\n"), transport: SpeechStub())
        await s1.open()
        try await prepareAll(s1)
        let before = files()

        var edited = paras
        edited[2] = rewritten
        let stub = SpeechStub()
        let s2 = session(body: edited.joined(separator: "\n\n"), transport: stub)
        await s2.open()
        let stale = s2.statuses.filter { $0 == .missing }.count
        XCTAssertEqual(stale, 1, "\(s2.statuses)")
        XCTAssertEqual(files().count, before.count - 1, "the replaced chunk's audio is removed")
        try await prepareAll(s2)
        XCTAssertEqual(stub.inputs, [rewritten])
    }

    func testChangingTheVoiceRegeneratesLazily() async throws {
        let s1 = session(transport: SpeechStub())
        await s1.open()
        try await prepareAll(s1)
        let stub = SpeechStub()
        let s2 = session(settings: NarrationSettings(model: "microsoft/mai-voice-2", voice: "en-US-Other:MAI-Voice-2"), transport: stub)
        await s2.open()
        XCTAssertTrue(s2.statuses.allSatisfy { $0 == .missing })
        XCTAssertEqual(files(), ["manifest.json"], "audio in the old voice is removed")
        _ = try await s2.prepare(chunk: 0)
        XCTAssertEqual(stub.requests.count, 1, "nothing is generated until it is played")
        XCTAssertEqual(stub.requests[0]["voice"] as? String, "en-US-Other:MAI-Voice-2")
    }

    func testPositionRoundTripsThroughTheManifest() async throws {
        let s1 = session(transport: SpeechStub())
        await s1.open()
        s1.setPosition(word: 17)
        XCTAssertEqual((try manifest()["position"] as? [String: Any])?["word"] as? Int, 17)
        let s2 = session(transport: SpeechStub())
        await s2.open()
        XCTAssertEqual(s2.position, 17)
        XCTAssertEqual(s2.progress(atWord: s2.script.words.count - 1), 1)
    }

    // MARK: Errors

    func testRateLimitsAndServerErrorsAreRetried() async throws {
        let stub = SpeechStub()
        stub.failures = [(429, #"{"error":{"message":"slow down"}}"#), (503, "{}")]
        let s = session(transport: stub)
        await s.open()
        _ = try await s.prepare(chunk: 0)
        XCTAssertEqual(stub.requests.count, 3)
        XCTAssertEqual(s.statuses[0], .ready)
    }

    func testOutOfCreditsFailsTheChunkWithoutLeakingTheKeyOrText() async throws {
        let stub = SpeechStub()
        let s = session(transport: stub)
        await s.open()
        let text = s.script.chunks[0].text
        stub.failures = [(402, #"{"error":{"code":402,"message":"no credits for sk-or-secret: \#(text)"}}"#)]
        do { _ = try await s.prepare(chunk: 0); XCTFail("expected failure") } catch {}
        XCTAssertEqual(stub.requests.count, 1, "402 is not retried")
        guard case .failed(let msg) = s.statuses[0] else { return XCTFail("\(s.statuses[0])") }
        XCTAssertTrue(msg.contains("402"), msg)
        XCTAssertFalse(msg.contains("sk-or-secret"), msg)
        XCTAssertFalse(msg.contains(text), msg)
        XCTAssertFalse(files().contains { $0.hasSuffix(".mp3") })
        // Retry works once credits are back.
        _ = try await s.prepare(chunk: 0)
        XCTAssertEqual(s.statuses[0], .ready)
    }

    func testNonAudioRepliesAreRejected() async throws {
        let stub = SpeechStub()
        stub.contentType = "text/html"
        let s = session(transport: stub)
        await s.open()
        do { _ = try await s.prepare(chunk: 0); XCTFail("expected failure") } catch {}
        guard case .failed(let msg) = s.statuses[0] else { return XCTFail() }
        XCTAssertTrue(msg.contains("text/html"), msg)
    }

    func testMissingKeyFailsWithAHint() async throws {
        let s = NarrationSession(item: item, body: body, folder: folder, settings: NarrationSettings(), pronunciations: [:],
                                 keys: InMemoryAPIKeyStore(key: nil), transport: SpeechStub(), transcriber: nil,
                                 durationOf: { _ in 5 }, retryDelays: [])
        do { _ = try await s.prepare(chunk: 0); XCTFail() } catch { XCTAssertEqual(error as? NarrationError, .missingKey) }
    }

    // MARK: Timing

    func testAlignmentTimesEveryWordAndNeverGoesBackwards() async throws {
        let echo = EchoTranscriber()
        // Mishear one word, drop another, insert noise.
        echo.edit = { words in
            var w = words
            if w.count > 6 { w[3] = "wobble"; w.remove(at: 5); w.insert("um", at: 2) }
            return w
        }
        let s = session(transport: SpeechStub(), transcriber: echo, duration: 30)
        await s.open()
        let c = 1
        _ = try await s.prepare(chunk: c)
        await s.waitForAlignment()
        let starts = try XCTUnwrap(s.starts(chunk: c))
        XCTAssertEqual(starts.count, s.script.chunks[c].words.count)
        XCTAssertEqual(starts, starts.sorted(), "monotonic")
        XCTAssertEqual(starts[0], 0, accuracy: 0.001)
        // Exactly heard words land on their recognised times (0.5 s apart in the echo).
        let lastHeard = Double(s.script.words[s.script.chunks[c].words].filter { !$0.spoken.isEmpty }.count) * 0.5
        XCTAssertLessThan(starts.last!, lastHeard + 0.01)
        XCTAssertEqual((try manifest()["chunks"] as? [String: [String: Any]])?.values.first { ($0["aligned"] as? Bool) == true } != nil, true)
        XCTAssertGreaterThan(s.timingRevision, 0)
    }

    /// What a real chunk did: the recogniser missed the first part of the audio, and its first heard word ("search")
    /// also occurs early in the script. The early match must not stretch the opening words and squeeze the rest.
    func testAMissedStretchOfAudioDoesNotStretchOrSqueezeTheWords() async throws {
        let filler = (1...30).map { "Item \($0) needs full text search here." }.joined(separator: " ")   // 210 words
        let s = session(body: "Opening words about search engines. " + filler, transport: SpeechStub(), transcriber: nil)
        let c = s.script.chunks.firstIndex { s.script.words[$0.words].contains { $0.written == "Opening" } }!
        let words = Array(s.script.words[s.script.chunks[c].words])
        let truth = words.indices.map { Double($0) * 0.5 }
        let cut = words.count * 6 / 10
        // Heard: nothing before `cut`, then everything with its true time.
        let heard = (cut..<words.count).map { TimedWord(start: truth[$0], text: words[$0].spoken) }
        let starts = try XCTUnwrap(WordAligner.align(words, recognised: heard, duration: truth.last! + 0.5))
        XCTAssertEqual(starts, starts.sorted())
        // After the gap: on the heard times.
        for i in stride(from: cut + 2, to: words.count, by: 7) { XCTAssertEqual(starts[i], truth[i], accuracy: 0.6, "word \(i)") }
        // Inside the gap: spread over it, not crawling (word 5 is "search."; a wrong match would put it at the cut).
        let opening = words.firstIndex { $0.written == "search" }!
        XCTAssertLessThan(starts[opening], truth[cut] / 2)
        for i in stride(from: 1, to: cut, by: 9) { XCTAssertEqual(starts[i], truth[i], accuracy: truth[cut] * 0.35, "word \(i)") }
    }

    func testTimesFromAnOlderAlignerAreRedone() async throws {
        let s1 = session(transport: SpeechStub(), transcriber: EchoTranscriber(), duration: 30)
        await s1.open()
        _ = try await s1.prepare(chunk: 1)
        await s1.waitForAlignment()
        // Rewrite the saved chunk as version 1 with nonsense times.
        let url = folder.appendingPathComponent("manifest.json")
        var m = try JSONDecoder.narration.decode(NarrationManifest.self, from: Data(contentsOf: url))
        let key = s1.script.chunks[1].key
        m.chunks[key]!.alignVersion = nil
        m.chunks[key]!.starts = m.chunks[key]!.starts.map { _ in 29 }
        try JSONEncoder.narration.encode(m).write(to: url)

        let s2 = session(transport: SpeechStub(), transcriber: EchoTranscriber(), duration: 30)
        await s2.open()
        let p = try await s2.prepare(chunk: 1)
        XCTAssertEqual(p.starts.first, 0, "plays on the estimate meanwhile")
        await s2.waitForAlignment()
        let redone = try XCTUnwrap(s2.starts(chunk: 1))
        XCTAssertEqual(redone[1], 0.5, accuracy: 0.01)
        let saved = try JSONDecoder.narration.decode(NarrationManifest.self, from: Data(contentsOf: url)).chunks[key]!
        XCTAssertEqual(saved.alignVersion, WordAligner.version)
    }

    func testWithoutRecognitionTimesAreEstimatedOverTheChunk() async throws {
        let echo = EchoTranscriber()
        echo.error = TranscriptionError.notAuthorized
        let s = session(transport: SpeechStub(), transcriber: echo, duration: 12)
        await s.open()
        let p = try await s.prepare(chunk: 1)
        await s.waitForAlignment()
        XCTAssertEqual(p.starts.first, 0)
        XCTAssertEqual(p.starts, p.starts.sorted())
        XCTAssertLessThan(p.starts.last!, 12)
        XCTAssertEqual(s.starts(chunk: 1), p.starts, "the estimate stands")
        XCTAssertEqual(s.statuses[1], .ready, "audio never waits on alignment")
    }

    func testWordAtAndSeekAgree() async throws {
        let s = session(transport: SpeechStub(), transcriber: EchoTranscriber(), duration: 60)
        await s.open()
        let target = s.script.chunks[1].words.lowerBound + 4
        let (chunk, offset) = try await s.seek(toWord: target)
        await s.waitForAlignment()
        XCTAssertEqual(chunk.index, 1)
        let aligned = try await s.seek(toWord: target)
        XCTAssertEqual(s.wordAt(chunk: 1, time: aligned.offset + 0.01), target)
        XCTAssertEqual(s.wordAt(chunk: 1, time: 0), s.script.chunks[1].words.lowerBound)
        XCTAssertGreaterThanOrEqual(offset, 0)
    }
}
