import XCTest
import DeepwellModel
import DeepwellYouTube
@testable import DeepwellTranscription

struct DirAccess: FolderAccessing {
    let url: URL
    func withFolder<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
}

struct FileResolver: AudioURLResolver {
    var fail: String?
    func audioURL(for item: Item) async throws -> URL {
        if let fail { throw TranscriptionError.audioUnavailable(fail) }
        return URL(fileURLWithPath: "/dev/null")
    }
}

final class StubTranscriber: Transcriber, @unchecked Sendable {
    var result: Result<[TimedWord], Error>
    var calls = 0
    var concurrent = 0, maxConcurrent = 0
    init(_ result: Result<[TimedWord], Error>) { self.result = result }
    func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        calls += 1; concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        progress(0.5)
        await Task.yield()
        return try result.get()
    }
}

final class TranscriptionTests: XCTestCase {
    var dir: URL!
    var stateURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-tr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("state/queue.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func writeItem(id: String, needs: Bool = true, type: ItemType = .youtube, offset: TimeInterval = 0) throws -> URL {
        var item = Item(id: id, type: type, title: "Video \(id)",
                        sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset))
        if needs { item.markNeedsTranscript() }
        let url = dir.appendingPathComponent("lib/\(id).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FrontmatterCodec.encode(ItemDocument(item: item, body: "_No captions._")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeQueue(_ t: Transcriber, resolver: AudioURLResolver = FileResolver()) -> TranscriptionQueue {
        MainActor.assumeIsolated {
            TranscriptionQueue(
                library: FolderTranscriptionLibrary(access: DirAccess(url: dir.appendingPathComponent("lib"))),
                store: TranscriptionStateStore(url: stateURL),
                audio: AudioSource(resolvers: [.youtube: resolver, .podcast: resolver]),
                transcriber: t)
        }
    }

    let words = [TimedWord(start: 0, text: "Hello"), TimedWord(start: 1, text: "world."),
                 TimedWord(start: 31, text: "Second"), TimedWord(start: 32, text: "paragraph.")]

    func testFormatterMatchesTicket05ShapeAndParses() {
        let item = Item(type: .youtube, title: "t", sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let body = TranscriptFormatter.body(for: words, item: item)
        XCTAssertEqual(body, "[0:00](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=0s) Hello world.\n\n[0:31](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=31s) Second paragraph.\n")
        let segs = TranscriptParser.parse(body)
        XCTAssertEqual(segs.map(\.startSeconds), [0, 31])
        XCTAssertEqual(segs.last?.text, "Second paragraph.")
    }

    @MainActor func testTranscribesInOrderOneAtATimeAndClearsMarker() async throws {
        try writeItem(id: "a", offset: 0)
        try writeItem(id: "b", offset: 10)
        try writeItem(id: "c", needs: false)
        let t = StubTranscriber(.success(words))
        let q = makeQueue(t)
        q.start()
        XCTAssertEqual(q.entries.map(\.id), ["a", "b"])
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 2)
        XCTAssertEqual(t.maxConcurrent, 1)
        XCTAssertTrue(q.entries.isEmpty)
        let doc = try FrontmatterCodec.decode(String(contentsOf: dir.appendingPathComponent("lib/a.md")))
        XCTAssertFalse(doc.item.needsTranscript)
        XCTAssertTrue(doc.body.hasPrefix("[0:00]("))
        XCTAssertEqual(doc.item.title, "Video a")
        let untouched = try String(contentsOf: dir.appendingPathComponent("lib/c.md"))
        XCTAssertTrue(untouched.contains("_No captions._"))
    }

    @MainActor func testFailureKeepsItemMarkedThenRetrySucceeds() async throws {
        let file = try writeItem(id: "a")
        let t = StubTranscriber(.failure(TranscriptionError.notAuthorized))
        let q = makeQueue(t)
        q.start()
        await q.waitUntilIdle()
        guard case .failed(let msg) = q.status(for: "a") else { return XCTFail("expected failed, got \(String(describing: q.status(for: "a")))") }
        XCTAssertTrue(msg.contains("not authorized"))
        XCTAssertTrue(try String(contentsOf: file).contains("needs_transcript: true"), "item stays saved and marked")
        XCTAssertEqual(t.calls, 1)

        // start() again must not auto-retry a failed item.
        q.start(); await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 1)

        t.result = .success(words)
        q.retry(id: "a")
        await q.waitUntilIdle()
        XCTAssertNil(q.status(for: "a"))
        XCTAssertFalse(try String(contentsOf: file).contains("needs_transcript"))
    }

    @MainActor func testAudioUnavailableAndEmptyTranscriptFail() async throws {
        try writeItem(id: "a")
        let q = makeQueue(StubTranscriber(.success(words)), resolver: FileResolver(fail: "no audio"))
        q.start(); await q.waitUntilIdle()
        XCTAssertEqual(q.status(for: "a"), .failed("no audio"))

        try? FileManager.default.removeItem(at: stateURL)
        let q2 = makeQueue(StubTranscriber(.success([])))
        q2.start(); await q2.waitUntilIdle()
        XCTAssertEqual(q2.status(for: "a"), .failed(TranscriptionError.noSpeechDetected.localizedDescription))
    }

    @MainActor func testResumesAfterRestartAndPersistsFailures() async throws {
        try writeItem(id: "a", offset: 0)
        try writeItem(id: "b", offset: 10)
        let q1 = makeQueue(StubTranscriber(.failure(TranscriptionError.noSpeechDetected)))
        q1.sync()   // never started: simulates quit before work began
        XCTAssertEqual(TranscriptionStateStore(url: stateURL).load().map(\.id), ["a", "b"])

        // "Restart": a fresh queue reads the state file, plus a new marked item appears meanwhile.
        try writeItem(id: "c", offset: 20)
        let t = StubTranscriber(.success(words))
        let q2 = makeQueue(t)
        XCTAssertEqual(q2.entries.map(\.id), ["a", "b"])
        q2.start()
        XCTAssertEqual(q2.entries.map(\.id), ["a", "b", "c"])
        await q2.waitUntilIdle()
        XCTAssertEqual(t.calls, 3)

        // Failures survive a restart and are not auto-retried.
        try writeItem(id: "d", offset: 30)
        let q3 = makeQueue(StubTranscriber(.failure(TranscriptionError.noSpeechDetected)))
        q3.start(); await q3.waitUntilIdle()
        let t4 = StubTranscriber(.success(words))
        let q4 = makeQueue(t4)
        q4.start(); await q4.waitUntilIdle()
        XCTAssertEqual(t4.calls, 0)
        XCTAssertTrue(q4.status(for: "d")?.isFailed == true)
    }

    @MainActor func testEntryDroppedWhenMarkerClearedElsewhere() async throws {
        try writeItem(id: "a")
        let q = makeQueue(StubTranscriber(.success(words)))
        q.sync()
        XCTAssertEqual(q.entries.count, 1)
        try writeItem(id: "a", needs: false)
        q.sync()
        XCTAssertTrue(q.entries.isEmpty)
    }

    func testYouTubeStubExplainsLimitation() async {
        do { _ = try await YouTubeAudioResolverStub().audioURL(for: Item(type: .youtube, title: "x")); XCTFail() }
        catch { XCTAssertTrue((error as? TranscriptionError)?.errorDescription?.contains("YouTube") == true) }
    }
}
