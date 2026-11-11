import XCTest
import DeepwellModel
import DeepwellMenu
import DeepwellTranscription
import DeepwellTagging
@testable import DeepwellNarration

/// Ticket 17: the phone and the Mac share `<item>.narration/` through iCloud. Two sessions on one folder stand in for
/// the two devices.
@MainActor
final class ListenOnPhoneTests: XCTestCase {
    var library: URL!
    var itemFile: URL!
    let keys = InMemoryAPIKeyStore(key: "sk-or-secret")
    let item = Item(type: .article, title: "On Wells", author: "Ada Lovelace")
    let body = (1...4).map { n in (1...32).map { "Paragraph \(n) sentence \($0)." }.joined(separator: " ") }
        .joined(separator: "\n\n")

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        itemFile = library.appendingPathComponent("2026-11-11-wells-abcd1234.md")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: library) }

    private var folder: URL { NarrationSession.folder(forItemFile: itemFile) }
    private var manifestURL: URL { folder.appendingPathComponent("manifest.json") }

    func device(_ stub: SpeechStub = SpeechStub(), settings: NarrationSettings = NarrationSettings()) -> NarrationSession {
        NarrationSession(item: item, body: body, folder: folder, settings: settings, pronunciations: [:], keys: keys,
                         transport: stub, transcriber: nil, durationOf: { _ in 10 }, retryDelays: [0, 0, 0])
    }

    // MARK: Position sync

    func testStoppingOnOneDeviceAndResumingOnTheOther() async throws {
        let mac = device(); await mac.open()
        let phone = device(); await phone.open()
        mac.setPosition(word: 40)   // stop on the Mac
        let r1 = await phone.refreshPosition()
        XCTAssertTrue(r1)
        XCTAssertEqual(phone.position, 40)
        phone.setPosition(word: 75)  // listen on, stop on the phone
        let r2 = await mac.refreshPosition()
        XCTAssertTrue(r2)
        XCTAssertEqual(mac.position, 75)
        let r3 = await mac.refreshPosition()
        XCTAssertFalse(r3, "nothing newer the second time")
    }

    func testAnOlderSessionSavingChunksKeepsTheNewerPosition() async throws {
        let phone = device(); await phone.open()
        let mac = device(); await mac.open()
        mac.setPosition(word: 50)
        _ = try await phone.prepare(chunk: 1)   // the phone saves its manifest after the Mac's stop
        let saved = try JSONDecoder.narration.decode(NarrationManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(saved.position?.word, 50)
        XCTAssertNotNil(saved.chunks[phone.script.chunks[1].key])
    }

    func testAManifestFromABuildBeforeTicket17StillGivesItsPosition() async throws {
        let s = device(); await s.open()
        let old = """
        {"chunks":{},"model":"\(NarrationSettings.defaultModel)","position":{"chunk":0,"word":12},\
        "updatedAt":"2030-01-01T00:00:00Z","version":1,"voice":"\(NarrationSettings().voice)"}
        """
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: manifestURL)
        let r4 = await s.refreshPosition()
        XCTAssertTrue(r4)
        XCTAssertEqual(s.position, 12)
        let next = device(); await next.open()
        XCTAssertEqual(next.position, 12)
    }

    func testAnotherVoicesPositionIsNotAdopted() async throws {
        let mac = device(); await mac.open()
        let phone = device(settings: NarrationSettings(model: "microsoft/mai-voice-2", voice: "en-US-Other:MAI-Voice-2"))
        await phone.open()
        mac.setPosition(word: 30)
        let r5 = await phone.refreshPosition()
        XCTAssertFalse(r5)
    }

    // MARK: Chunk reuse

    func testChunkKeysDependOnlyOnModelVoiceAndText() {
        let a = NarrationScript.build(item: item, body: body, pronunciations: [:], model: "m", voice: "v")
        let b = NarrationScript.build(item: item, body: body, pronunciations: [:], model: "m", voice: "v")
        XCTAssertEqual(a.chunks.map(\.key), b.chunks.map(\.key))
        // Golden value: the Mac and the phone must agree byte for byte (sha256, length-prefixed fields).
        let c = NarrationScript.build(item: Item(type: .article, title: "T"), body: "Hello there.", pronunciations: [:],
                                      model: "m", voice: "v")
        XCTAssertEqual(c.chunks.first?.key.count, 64)
        XCTAssertEqual(c.chunks.first?.key, Self.goldenKey)
    }
    static let goldenKey = "c45be76da6f357710e3d11cec6454587e1b0cb1cb450c9ec28cd37f7dbe04d88"

    func testChunksTheOtherDeviceMadeAreReusedWithoutARequest() async throws {
        let macStub = SpeechStub(), phoneStub = SpeechStub()
        let mac = device(macStub); await mac.open()
        let phone = device(phoneStub); await phone.open()   // opened before the Mac generated anything
        _ = try await mac.prepare(chunk: 0)
        _ = try await mac.prepare(chunk: 1)
        let p = try await phone.prepare(chunk: 1)
        XCTAssertEqual(phoneStub.requests.count, 0)
        XCTAssertEqual(p.file.lastPathComponent, "\(phone.script.chunks[1].key.prefix(20)).mp3")
        // Both devices' chunks survive each other's saves.
        _ = try await phone.prepare(chunk: 2)
        mac.setPosition(word: 3)
        let saved = try JSONDecoder.narration.decode(NarrationManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(Set(saved.chunks.keys), Set(mac.script.chunks[0...2].map(\.key)))
    }

    // MARK: Timeline

    func testWordTimesRunThroughTheArticle() async throws {
        let s = device(); await s.open()
        _ = try await s.prepare(chunk: 0)
        let times = s.wordTimes()
        XCTAssertEqual(times.count, s.script.words.count)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(s.elapsed(chunk: 1, offset: 2), 12, accuracy: 0.001)
        XCTAssertGreaterThan(s.totalDuration, 10)
    }

    // MARK: Remote commands

    /// Ten sentences of four words, 1 s per word.
    let sentences = (0..<10).map { ($0 * 4)..<($0 * 4 + 4) }
    func sentenceOf(_ w: Int) -> Int { w / 4 }
    var times: [TimeInterval] { (0..<40).map(Double.init) }

    func testSkipForwardFifteenSecondsLandsOnTheNextSentenceStart() {
        // From word 5 (t = 5) to t = 20 = word 20, a sentence start.
        XCTAssertEqual(NarrationControls.skip(from: 5, by: 15, times: times, sentences: sentences, sentenceOf: sentenceOf), 20)
        // From word 6 to t = 21 (mid-sentence 5): the start of sentence 6.
        XCTAssertEqual(NarrationControls.skip(from: 6, by: 15, times: times, sentences: sentences, sentenceOf: sentenceOf), 24)
        // Near the end: the last sentence.
        XCTAssertEqual(NarrationControls.skip(from: 37, by: 15, times: times, sentences: sentences, sentenceOf: sentenceOf), 36)
    }

    func testSkipBackFifteenSecondsLandsOnASentenceStartAndAlwaysMovesBack() {
        // From word 22 (t = 22) to t = 7: sentence 1 starts at word 4.
        XCTAssertEqual(NarrationControls.skip(from: 22, by: -15, times: times, sentences: sentences, sentenceOf: sentenceOf), 4)
        // Early in the article: the start.
        XCTAssertEqual(NarrationControls.skip(from: 3, by: -15, times: times, sentences: sentences, sentenceOf: sentenceOf), 0)
        // A tiny skip still goes back a sentence.
        XCTAssertEqual(NarrationControls.skip(from: 9, by: -0.5, times: times, sentences: sentences, sentenceOf: sentenceOf), 4)
    }

    func testSentenceStepsAndRates() {
        XCTAssertEqual(NarrationControls.previousSentence(word: 9, sentences: sentences, sentenceOf: sentenceOf, sinceSentenceStart: 3), 8)
        XCTAssertEqual(NarrationControls.previousSentence(word: 9, sentences: sentences, sentenceOf: sentenceOf, sinceSentenceStart: 0.5), 4)
        XCTAssertEqual(NarrationControls.previousSentence(word: 1, sentences: sentences, sentenceOf: sentenceOf, sinceSentenceStart: 0.5), 0)
        XCTAssertEqual(NarrationControls.nextSentence(word: 9, sentences: sentences, sentenceOf: sentenceOf), 12)
        XCTAssertNil(NarrationControls.nextSentence(word: 38, sentences: sentences, sentenceOf: sentenceOf))
        XCTAssertEqual(NarrationControls.nearestSpeed(1.17), 1.15)
        XCTAssertEqual(NarrationControls.nearestSpeed(3), 2)
        XCTAssertEqual(NarrationControls.nearestSpeed(0.5), 0.8)
        XCTAssertTrue(NarrationControls.resumeAfterInterruption(wasPlaying: true, shouldResume: true))
        XCTAssertFalse(NarrationControls.resumeAfterInterruption(wasPlaying: false, shouldResume: true))
        XCTAssertFalse(NarrationControls.resumeAfterInterruption(wasPlaying: true, shouldResume: false))
    }

    // MARK: Offline pinning

    func testPinsFollowTheQueueAndSkipItemsNotInTheIndex() throws {
        let json = """
        {"weekStart":0,"pickedAt":0,"topic":"Wells","entries":[
          {"itemID":"a","title":"A","minutes":5,"reason":""},
          {"itemID":"gone","title":"Gone","minutes":5,"reason":""},
          {"itemID":"b","title":"B","minutes":5,"reason":""},
          {"itemID":"a","title":"A again","minutes":5,"reason":""}]}
        """
        let queue = try JSONDecoder().decode(WeekQueue.self, from: Data(json.utf8))
        let root = URL(fileURLWithPath: "/lib")
        let pins = OfflinePins.pins(queue: queue, relativePaths: ["a": "2026-a.md", "b": "sub/2026-b.md"], library: root)
        XCTAssertEqual(pins.map(\.itemID), ["a", "b"])
        XCTAssertEqual(pins[1].item.path, "/lib/sub/2026-b.md")
        XCTAssertEqual(pins[1].narration.path, "/lib/sub/2026-b.narration")
        XCTAssertEqual(OfflinePins.pins(queue: nil, relativePaths: ["a": "x.md"], library: root), [])
    }

    func testBadgeState() throws {
        XCTAssertEqual(OfflinePins.state(item: .local, narration: []), .downloaded)
        XCTAssertEqual(OfflinePins.state(item: .local, narration: [.local, .downloading]), .downloading)
        XCTAssertEqual(OfflinePins.state(item: .remote, narration: [.local]), .notDownloaded)
        XCTAssertEqual(OfflinePins.state(item: .remote, narration: [.downloading]), .downloading)

        // Outside iCloud (this temp folder): files on disk are local, a placeholder is not.
        try Data("x".utf8).write(to: itemFile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".abc.mp3.icloud"))
        let pin = try XCTUnwrap(OfflinePins.pins(queue: try JSONDecoder().decode(WeekQueue.self, from: Data("""
            {"weekStart":0,"pickedAt":0,"topic":"T","entries":[{"itemID":"a","title":"A","minutes":1,"reason":""}]}
            """.utf8)), relativePaths: ["a": itemFile.lastPathComponent], library: library).first)
        XCTAssertEqual(OfflinePins.state(of: pin), .notDownloaded)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".abc.mp3.icloud"))
        try Data("mp3".utf8).write(to: folder.appendingPathComponent("abc.mp3"))
        XCTAssertEqual(OfflinePins.state(of: pin), .downloaded)
    }

    // MARK: SpeechAnalyzer runs

    func testRecogniserRunsBecomeWords() {
        let runs = [TimedRun(text: "The", start: 0), TimedRun(text: " well", start: 0.3), TimedRun(text: " was", start: 0.7),
                    TimedRun(text: "n't", start: 0.9), TimedRun(text: " deep at all.", start: 1.2)]
        XCTAssertEqual(TimedRuns.words(from: runs), [
            TimedWord(start: 0, text: "The"), TimedWord(start: 0.3, text: "well"), TimedWord(start: 0.7, text: "wasn't"),
            TimedWord(start: 1.2, text: "deep"), TimedWord(start: 1.2, text: "at"), TimedWord(start: 1.2, text: "all."),
        ])
    }

    func testFallbackTranscriberUsesTheFallbackWhenThePrimaryFails() async throws {
        struct Failing: Transcriber {
            func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
                throw TranscriptionError.recognizerUnavailable("no model")
            }
        }
        struct Fixed: Transcriber {
            func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
                [TimedWord(start: 0, text: "ok")]
            }
        }
        let t = FallbackTranscriber(primary: Failing(), fallback: Fixed())
        let words = try await t.transcribe(audioFile: itemFile, progress: { _ in })
        XCTAssertEqual(words.map(\.text), ["ok"])
    }
}
