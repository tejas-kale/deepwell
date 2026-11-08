import XCTest
import DeepwellModel
import DeepwellLibrary
@testable import DeepwellTagging

final class StubModel: TaggingModel, @unchecked Sendable {
    var response: Result<[String], Error>
    private(set) var calls: [(title: String, vocabulary: [String])] = []
    init(_ r: Result<[String], Error>) { response = r }
    func suggestTags(title: String, text: String, vocabulary: [String]) async throws -> [String] {
        calls.append((title, vocabulary)); return try response.get()
    }
}

struct TempLibrary: LibraryAccessing {
    let url: URL
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
}

struct StubTransport: HTTPTransport {
    var handler: @Sendable (URLRequest) throws -> (Data, Int)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, code) = try handler(request)
        return (d, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ v: T? = nil) { value = v }
}

private func reply(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
}

final class TaggerTests: XCTestCase {
    func testReusesVocabularyCaseAndSeparatorInsensitively() throws {
        let r = try Tagger.resolve(["Distributed Systems", "ml_ops"], vocabulary: ["distributed-systems", "MLOps"])
        XCTAssertEqual(r.tags, ["distributed-systems", "ml-ops"])
        XCTAssertEqual(r.newTags, ["ml-ops"])
    }
    func testAllReusedMeansNoNewTags() throws {
        let r = try Tagger.resolve(["rust", "databases"], vocabulary: ["rust", "databases", "go"])
        XCTAssertEqual(r.newTags, [])
    }
    func testCapsAtFourDedupesAndDropsBlanks() throws {
        let r = try Tagger.resolve(["a", "A", " ", "b", "c", "d", "e"], vocabulary: [])
        XCTAssertEqual(r.tags, ["a", "b", "c", "d"])
        XCTAssertEqual(r.newTags, ["a", "b", "c", "d"])
    }
    func testEmptySuggestionsThrow() {
        XCTAssertThrowsError(try Tagger.resolve(["", "  "], vocabulary: [])) { XCTAssertEqual($0 as? TaggingError, .noTags) }
    }
}

final class AnthropicClientTests: XCTestCase {
    func testRequestShapeAndPromptContainsVocabulary() async throws {
        let captured = Box<URLRequest>()
        let model = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(key: "sk-test"),
                                          transport: StubTransport { req in captured.value = req; return (reply("[\"rust\"]"), 200) })
        let tags = try await model.suggestTags(title: "T", text: "body", vocabulary: ["rust", "go"])
        XCTAssertEqual(tags, ["rust"])
        let req = try XCTUnwrap(captured.value)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        let msg = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(msg.contains("[\"rust\",\"go\"]"))
    }

    func testParsesFencedJSON() async throws {
        let model = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(key: "k"),
                                          transport: StubTransport { _ in (reply("```json\n[\"a\", \"b\"]\n```"), 200) })
        let tags = try await model.suggestTags(title: "", text: "", vocabulary: [])
        XCTAssertEqual(tags, ["a", "b"])
    }

    func testMissingKeyAPIErrorAndMalformed() async {
        let noKey = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(), transport: StubTransport { _ in XCTFail(); return (Data(), 200) })
        await assertThrows(noKey, .missingAPIKey)
        let err = try! JSONSerialization.data(withJSONObject: ["error": ["message": "overloaded"]])
        let api = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(key: "k"), transport: StubTransport { _ in (err, 529) })
        await assertThrows(api, .api(status: 529, message: "overloaded"))
        let bad = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(key: "k"), transport: StubTransport { _ in (reply("no tags here"), 200) })
        await assertThrows(bad, .malformedResponse)
        let net = AnthropicTaggingModel(keys: InMemoryAPIKeyStore(key: "k"), transport: StubTransport { _ in throw TaggingError.network("offline") })
        await assertThrows(net, .network("offline"))
    }

    private func assertThrows(_ m: AnthropicTaggingModel, _ expected: TaggingError, line: UInt = #line) async {
        do { _ = try await m.suggestTags(title: "", text: "", vocabulary: []); XCTFail("no throw", line: line) }
        catch { XCTAssertEqual(error as? TaggingError, expected, line: line) }
    }
}

final class TaggingServiceTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tagging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ title: String, tags: [String] = [], extra: [String] = []) throws -> URL {
        let item = Item(type: .article, title: title, tags: tags, extraFrontmatter: extra)
        return try ItemFileWriter.write(ItemDocument(item: item, body: "Body of \(title)"), into: dir)
    }
    func read(_ url: URL) throws -> Item { try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8)).item }

    func service(_ model: TaggingModel, key: String? = "k", clock: Box<Date>? = nil) -> TaggingService {
        TaggingService(library: TempLibrary(url: dir), model: model, keys: InMemoryAPIKeyStore(key: key),
                       baseDelay: 60, now: { clock?.value ?? Date() })
    }

    func testTagsUntaggedItemSendsExistingVocabularyAndFlagsNewTags() async throws {
        try write("Old", tags: ["rust", "databases"])
        let url = try write("New")
        let stub = StubModel(.success(["Rust", "wasm"]))
        let summary = await service(stub).processPending()
        XCTAssertEqual(summary.tagged.count, 1)
        XCTAssertEqual(Set(stub.calls[0].vocabulary), ["rust", "databases"])
        let item = try read(url)
        XCTAssertEqual(item.tags, ["rust", "wasm"])
        XCTAssertEqual(NewTagFlag.read(item), ["wasm"])
    }

    func testFlagSurvivesRoundTripAndAlreadyTaggedItemsAreUntouched() async throws {
        let tagged = try write("Tagged", tags: ["go"])
        let before = try String(contentsOf: tagged)
        let url = try write("Fresh", extra: ["custom: keep-me"])
        _ = await service(StubModel(.success(["go", "zig"]))).processPending()
        XCTAssertEqual(try String(contentsOf: tagged), before)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("new_tags: [\"zig\"]"))
        XCTAssertTrue(text.contains("custom: keep-me"))
        XCTAssertEqual(NewTagFlag.read(try read(url)), ["zig"])
    }

    func testNoNewTagsWritesNoFlag() async throws {
        try write("Old", tags: ["go"])
        let url = try write("Fresh")
        _ = await service(StubModel(.success(["go"]))).processPending()
        XCTAssertFalse(try String(contentsOf: url).contains("new_tags"))
    }

    func testMissingKeyLeavesItemUntaggedAndNeverCallsModel() async throws {
        let url = try write("Fresh")
        let stub = StubModel(.success(["x"]))
        let s = await service(stub, key: nil).processPending()
        XCTAssertTrue(s.missingKey)
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(try read(url).tags.isEmpty)
    }

    func testFailureLeavesItemUntaggedBacksOffThenRetries() async throws {
        let url = try write("Fresh")
        let stub = StubModel(.failure(TaggingError.network("offline")))
        let clock = Box<Date>(Date())
        let svc = service(stub, clock: clock)
        var s = await svc.processPending()
        XCTAssertEqual(s.failed, 1)
        XCTAssertTrue(try read(url).tags.isEmpty)
        s = await svc.processPending()                 // immediately: backing off
        XCTAssertEqual(s.skippedBackoff, 1)
        XCTAssertEqual(stub.calls.count, 1)
        clock.value = clock.value!.addingTimeInterval(61)
        stub.response = .success(["recovered"])
        s = await svc.processPending()
        XCTAssertEqual(s.tagged.count, 1)
        XCTAssertEqual(try read(url).tags, ["recovered"])
    }

    func testNewTagsFromEarlierItemAreVocabularyForLaterOnes() async throws {
        try write("A"); try write("B")
        let stub = StubModel(.success(["fresh-topic"]))
        _ = await service(stub).processPending()
        XCTAssertEqual(stub.calls[1].vocabulary, ["fresh-topic"])
    }
}

final class NewTagFlagTests: XCTestCase {
    func testRoundTripThroughCodecWithSpecialCharacters() throws {
        var item = Item(type: .article, title: "t", tags: ["a\"b", "c"])
        NewTagFlag.write(["a\"b"], to: &item)
        let decoded = try FrontmatterCodec.decode(FrontmatterCodec.encode(ItemDocument(item: item, body: "x"))).item
        XCTAssertEqual(NewTagFlag.read(decoded), ["a\"b"])
        var cleared = decoded; NewTagFlag.write([], to: &cleared)
        XCTAssertTrue(cleared.extraFrontmatter.isEmpty)
    }
}
