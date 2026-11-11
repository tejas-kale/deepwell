import XCTest
import DeepwellModel
@testable import DeepwellTranscription

/// Ticket 20: a Mac transcribes every `needs_transcript` item, wherever it was captured, and two Macs never run the
/// same item: a claim in the item (`processing_by` / `processing_at`) holds for an hour.
final class ClaimTests: XCTestCase {
    var dir: URL!
    var lib: URL { dir.appendingPathComponent("lib") }
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    let clock = Clock()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    let words = [TimedWord(start: 0, text: "Hello"), TimedWord(start: 1, text: "world.")]

    /// An item as the phone writes it after a share (podcast or YouTube, no published transcript).
    @discardableResult
    func writeItem(_ id: String, type: ItemType = .youtube, claim: ProcessingClaim? = nil) throws -> URL {
        var item = Item(id: id, type: type, title: "Shared \(id)",
                        sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        item.markNeedsTranscript()
        item.processingClaim = claim
        let url = lib.appendingPathComponent("\(id).md")
        try FrontmatterCodec.encode(ItemDocument(item: item, body: "_Transcript pending on Mac._")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func read(_ id: String) throws -> Item {
        try FrontmatterCodec.decode(String(contentsOf: lib.appendingPathComponent("\(id).md"), encoding: .utf8)).item
    }

    @MainActor func makeQueue(_ t: Transcriber, device: String = "Mac B") -> TranscriptionQueue {
        TranscriptionQueue(library: FolderTranscriptionLibrary(access: DirAccess(url: lib)),
                           store: TranscriptionStateStore(url: dir.appendingPathComponent("state-\(device).json")),
                           audio: AudioSource(resolvers: [.youtube: FileResolver(), .podcast: FileResolver()]),
                           transcriber: t, device: device, now: { [clock] in clock.now })
    }

    func testClaimRoundTripsThroughFrontmatter() throws {
        var item = Item(id: "x", type: .podcast, title: "t")
        item.processingClaim = ProcessingClaim(device: "Tejas's Mac: mini\n", at: clock.now)
        let decoded = try FrontmatterCodec.decode(FrontmatterCodec.encode(ItemDocument(item: item, body: ""))).item
        XCTAssertEqual(decoded.processingClaim?.device, "Tejas's Mac mini")
        XCTAssertEqual(decoded.processingClaim?.at, clock.now)
        XCTAssertTrue(decoded.extraFrontmatter.contains("processing_at: 2027-01-15T08:00:00Z"))
        item.processingClaim = nil
        XCTAssertTrue(item.extraFrontmatter.isEmpty)
    }

    func testClaimExpiresAfterAnHour() {
        let c = ProcessingClaim(device: "Mac A", at: clock.now)
        XCTAssertTrue(c.blocks("Mac B", at: clock.now.addingTimeInterval(3599)))
        XCTAssertFalse(c.blocks("Mac B", at: clock.now.addingTimeInterval(3600)))
        XCTAssertFalse(c.blocks("Mac A", at: clock.now), "a device's own claim never blocks it")
    }

    @MainActor func testDiscoversPhoneCapturesClaimsTranscribesAndClears() async throws {
        try writeItem("phone-video")
        try writeItem("phone-podcast", type: .podcast)
        let t = StubTranscriber(.success(words))
        let q = makeQueue(t)
        q.start()
        XCTAssertEqual(Set(q.entries.map(\.id)), ["phone-video", "phone-podcast"])
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 2)
        for id in ["phone-video", "phone-podcast"] {
            let item = try read(id)
            XCTAssertFalse(item.needsTranscript)
            XCTAssertNil(item.processingClaim, "claim cleared with the marker")
        }
    }

    @MainActor func testSecondMacsLiveClaimIsRespectedUntilItExpires() async throws {
        try writeItem("a", claim: ProcessingClaim(device: "Mac A", at: clock.now))
        try writeItem("b")
        let t = StubTranscriber(.success(words))
        let q = makeQueue(t)
        clock.now = clock.now.addingTimeInterval(30 * 60)
        q.start()
        XCTAssertEqual(q.entries.map(\.id), ["b"], "Mac A's item is left alone")
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 1)
        XCTAssertTrue(try read("a").needsTranscript)
        XCTAssertEqual(try read("a").processingClaim?.device, "Mac A")

        clock.now = clock.now.addingTimeInterval(31 * 60)   // 61 minutes after Mac A claimed it
        q.start()
        XCTAssertEqual(q.entries.map(\.id), ["a"])
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 2)
        XCTAssertFalse(try read("a").needsTranscript)
        XCTAssertNil(try read("a").processingClaim)
    }

    @MainActor func testClaimTakenAfterSyncMakesQueueBackOff() async throws {
        try writeItem("a")
        let t = StubTranscriber(.success(words))
        let q = makeQueue(t)
        q.sync()
        XCTAssertEqual(q.entries.map(\.id), ["a"])
        // Mac A's claim arrives between this Mac's sync and its worker reaching the item.
        try writeItem("a", claim: ProcessingClaim(device: "Mac A", at: clock.now))
        q.start()
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 0)
        XCTAssertTrue(q.entries.isEmpty)
        XCTAssertEqual(try read("a").processingClaim?.device, "Mac A")
    }

    @MainActor func testWhileTranscribingTheItemCarriesThisMacsClaim() async throws {
        try writeItem("a")
        final class Peek: Transcriber, @unchecked Sendable {
            let read: () -> Item?
            var seen: ProcessingClaim?
            init(read: @escaping () -> Item?) { self.read = read }
            func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
                seen = read()?.processingClaim
                return [TimedWord(start: 0, text: "Hi.")]
            }
        }
        let peek = Peek { [self] in try? read("a") }
        let q = makeQueue(peek)
        q.start()
        await q.waitUntilIdle()
        XCTAssertEqual(peek.seen?.device, "Mac B")
        XCTAssertEqual(peek.seen?.at, clock.now)
    }

    @MainActor func testFailureReleasesClaimButKeepsMarker() async throws {
        try writeItem("a")
        let q = makeQueue(StubTranscriber(.failure(TranscriptionError.notAuthorized)))
        q.start()
        await q.waitUntilIdle()
        XCTAssertTrue(q.status(for: "a")?.isFailed == true)
        XCTAssertTrue(try read("a").needsTranscript)
        XCTAssertNil(try read("a").processingClaim, "another Mac may try")
    }

    @MainActor func testWithoutDeviceNoClaimsAreWritten() async throws {
        try writeItem("a", claim: ProcessingClaim(device: "Mac A", at: clock.now))
        let t = StubTranscriber(.success(words))
        let q = TranscriptionQueue(library: FolderTranscriptionLibrary(access: DirAccess(url: lib)),
                                   store: TranscriptionStateStore(url: dir.appendingPathComponent("s.json")),
                                   audio: AudioSource(resolvers: [.youtube: FileResolver()]), transcriber: t)
        q.start()
        XCTAssertEqual(q.entries.map(\.id), ["a"], "claims are opt-in")
        await q.waitUntilIdle()
        XCTAssertEqual(t.calls, 1)
    }
}
