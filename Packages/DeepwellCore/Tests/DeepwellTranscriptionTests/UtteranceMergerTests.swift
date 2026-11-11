import XCTest
@testable import DeepwellTranscription

/// SFSpeechRecognizer on long audio: results refine the current utterance, then later results hold only the next one.
final class UtteranceMergerTests: XCTestCase {
    private func w(_ pairs: (Double, String)...) -> [TimedWord] { pairs.map { TimedWord(start: $0.0, text: $0.1) } }

    func testKeepsEveryUtteranceNotJustTheLast() {
        var m = UtteranceMerger()
        m.add(w((0.2, "Three")))
        m.add(w((0.2, "Three"), (0.9, "query"), (1.4, "patterns")))       // refines utterance 1
        m.add(w((5.0, "Keyword"), (5.6, "heavy")))                         // utterance 2 (only it)
        m.add(w((5.0, "Keyword"), (5.6, "heavy"), (6.1, "queries")))      // refines utterance 2
        XCTAssertEqual(m.words.map(\.text), ["Three", "query", "patterns", "Keyword", "heavy", "queries"])
    }

    func testUntimedPartialsAreIgnored() {
        var m = UtteranceMerger()
        m.add(w((0.2, "Hello"), (0.8, "world")))
        m.add(w((0, "Hello"), (0, "world"), (0, "again")))
        XCTAssertEqual(m.words.map(\.text), ["Hello", "world"])
    }

    func testAResultCoveringEverythingReplacesWhatItCovers() {
        var m = UtteranceMerger()
        m.add(w((0.2, "One")))
        m.add(w((3.0, "Two")))
        m.add(w((0.2, "One"), (3.0, "Two"), (4.0, "three")))
        XCTAssertEqual(m.words.map(\.text), ["One", "Two", "three"])
    }
}
