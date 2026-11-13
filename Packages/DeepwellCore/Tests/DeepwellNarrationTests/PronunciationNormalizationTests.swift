import XCTest
import DeepwellModel
@testable import DeepwellNarration

/// Built-in readings for words the voice mispronounces. The spoken form can be several words; the highlight still
/// covers the original token, and the next word's range does not move.
final class PronunciationNormalizationTests: XCTestCase {
    func testBuiltInTermsAreTheExtensionPoint() {
        XCTAssertEqual(PronunciationDictionary.terms["subagents"], "sub agents")
        XCTAssertEqual(PronunciationDictionary.terms["subagent"], "sub agent")
        XCTAssertEqual(PronunciationDictionary.terms["evals"], "ee vals")
        XCTAssertEqual(PronunciationDictionary.terms["eval"], "ee val")
        XCTAssertGreaterThanOrEqual(PronunciationDictionary.terms.count, 4)
    }

    func testSubagentsAndEvalsAreSpokenNaturallyWithoutMovingHighlights() {
        let body = """
        # Evals

        The subagents run nightly.
        """
        let script = NarrationScript.build(item: Item(type: .article, title: "Notes"), body: body,
                                            pronunciations: [:], model: "m", voice: "v")
        let blocks = ArticleBlocks.blocks(for: body)
        let located = script.words.filter { $0.location != nil }

        XCTAssertEqual(located.map(\.written), ["Evals", "The", "subagents", "run", "nightly."])
        XCTAssertEqual(located.map(\.spoken), ["ee vals.", "The", "sub agents", "run", "nightly."])

        for word in located {
            let loc = word.location!
            let plain = ArticleBlocks.plainText(blocks[loc.block].inlineMarkdown!)
            XCTAssertEqual(slice(plain, loc.range), word.written)
        }

        let sub = located.first { $0.written == "subagents" }!
        let run = located.first { $0.written == "run" }!
        XCTAssertEqual(sub.location?.block, run.location?.block)
        XCTAssertLessThan(sub.location!.range.upperBound, run.location!.range.lowerBound)
        XCTAssertEqual(slice(ArticleBlocks.plainText(blocks[sub.location!.block].inlineMarkdown!), sub.location!.range), "subagents")
        // One script word per written token: "sub agents" does not insert a word and shift the rest.
        XCTAssertEqual(script.words.filter { $0.location?.block == sub.location?.block }.count, 4)
    }

    func testCasePunctuationAndUnrelatedWords() {
        let body = "Subagents ship EVALS. A medieval evaluation is not an eval."
        let script = NarrationScript.build(item: Item(type: .article, title: "T"), body: body,
                                            pronunciations: [:], model: "m", voice: "v")
        let spoken = script.words.filter { $0.location != nil }
        XCTAssertEqual(spoken.map(\.written), ["Subagents", "ship", "EVALS.", "A", "medieval", "evaluation", "is", "not", "an", "eval."])
        XCTAssertEqual(spoken.map(\.spoken), ["sub agents", "ship", "ee vals.", "A", "medieval", "evaluation", "is", "not", "an", "ee val."])
        let plain = ArticleBlocks.plainText(ArticleBlocks.blocks(for: body)[0].inlineMarkdown!)
        for word in spoken {
            XCTAssertEqual(slice(plain, word.location!.range), word.written)
        }
    }

    func testCallerOverrideBeatsTheBuiltInReading() {
        let script = NarrationScript.build(item: Item(type: .article, title: "T"), body: "The evals passed.",
                                            pronunciations: ["evals": "evaluations"], model: "m", voice: "v")
        let evals = script.words.first { $0.written == "evals" }
        XCTAssertEqual(evals?.spoken, "evaluations")
        XCTAssertFalse(script.chunks.map(\.text).joined().contains("ee vals"))
    }

    func testUserFileOverridesTheBuiltInReading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PronunciationStore(libraryFolder: dir)
        XCTAssertEqual(PronunciationStore.presets["subagents"], "sub agents")
        XCTAssertEqual(PronunciationStore.presets["beehiiv"], "beehive")
        try store.save(["Evals": "evaluations"])
        let merged = store.merged()
        XCTAssertEqual(merged["Evals"], "evaluations")
        XCTAssertNil(merged["evals"], "the user's spelling replaces the built-in key")
        XCTAssertEqual(merged["subagents"], "sub agents")
        let script = NarrationScript.build(item: Item(type: .article, title: "T"), body: "Run evals.",
                                            pronunciations: merged, model: "m", voice: "v")
        XCTAssertEqual(script.words.first { $0.written == "evals." }?.spoken, "evaluations.")
    }

    private func slice(_ s: String, _ range: Range<Int>) -> String {
        let start = s.index(s.startIndex, offsetBy: range.lowerBound)
        let end = s.index(start, offsetBy: range.count)
        return String(s[start..<end])
    }
}
