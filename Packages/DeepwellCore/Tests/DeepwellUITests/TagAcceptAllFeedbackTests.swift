import XCTest
import DeepwellIndex
@testable import DeepwellCuration
@testable import DeepwellUI

/// Accept All New has to say what happened and clear the "new" badges, including when the model hands back the
/// same summaries it had before the tap.
final class TagAcceptAllFeedbackTests: XCTestCase {
    private func tag(_ name: String, count: Int = 2, new: Int) -> TagSummary {
        TagSummary(name: name, itemCount: count, newCount: new)
    }

    func testAcceptingEveryNewTagConfirmsAndClearsTheFlags() {
        let before = [tag("agents", new: 3), tag("evals", new: 1), tag("swift", new: 0)]
        let after = [tag("agents", new: 0), tag("evals", new: 0), tag("swift", new: 0)]
        let result = CurationResult(updated: ["a.md", "b.md"], failed: [:])
        let feedback = TagAcceptAllFeedback.make(before: before, after: after, result: result)
        XCTAssertEqual(feedback?.message, "Accepted 2 new tags.")
        XCTAssertEqual(feedback?.haptic, .success)
        XCTAssertEqual(feedback?.summaries.map(\.name), ["agents", "evals", "swift"])
        XCTAssertTrue(feedback?.summaries.allSatisfy { $0.newCount == 0 } == true)
        XCTAssertEqual(feedback?.summaries.map(\.itemCount), [2, 2, 2])
    }

    func testASingleNewTagIsNamed() {
        let before = [tag("zig", count: 4, new: 1)]
        let feedback = TagAcceptAllFeedback.make(before: before, after: [tag("zig", count: 4, new: 0)],
                                                  result: CurationResult(updated: ["a.md"], failed: [:]))
        XCTAssertEqual(feedback?.message, "Accepted \"zig\".")
        XCTAssertEqual(feedback?.haptic, .success)
        XCTAssertEqual(feedback?.summaries.first?.newCount, 0)
    }

    func testAStaleTagListStillDropsTheNewBadges() {
        let before = [tag("agents", new: 2), tag("evals", new: 2)]
        let result = CurationResult(updated: ["a.md"], failed: [:])
        let feedback = TagAcceptAllFeedback.make(before: before, after: before, result: result)
        XCTAssertEqual(feedback?.haptic, .success)
        XCTAssertEqual(feedback?.message, "Accepted 2 new tags.")
        XCTAssertEqual(feedback?.summaries.map(\.newCount), [0, 0])
        XCTAssertEqual(feedback?.summaries.map(\.name), ["agents", "evals"])
    }

    func testAFailedRunKeepsTheFlagsAndSaysSo() {
        let before = [tag("agents", new: 1)]
        let feedback = TagAcceptAllFeedback.make(before: before, after: before, result: nil)
        XCTAssertEqual(feedback?.message, "Couldn't accept new tags.")
        XCTAssertEqual(feedback?.haptic, .error)
        XCTAssertEqual(feedback?.summaries, before)

        let noneUpdated = CurationResult(updated: [], failed: ["a.md": "missing", "b.md": "locked"])
        let failed = TagAcceptAllFeedback.make(before: before, after: before, result: noneUpdated)
        XCTAssertEqual(failed?.message, "Couldn't update 2 files.")
        XCTAssertEqual(failed?.haptic, .error)
        XCTAssertEqual(failed?.summaries, before)
    }

    func testAPartialUpdateWarnsAndKeepsTheIndexFlags() {
        let before = [tag("agents", new: 2), tag("evals", new: 1)]
        let after = [tag("agents", new: 0), tag("evals", new: 1)]
        let result = CurationResult(updated: ["a.md"], failed: ["b.md": "evicted"])
        let feedback = TagAcceptAllFeedback.make(before: before, after: after, result: result)
        XCTAssertEqual(feedback?.message, "Accepted new tags. 1 file could not be updated.")
        XCTAssertEqual(feedback?.haptic, .warning)
        XCTAssertEqual(feedback?.summaries, after)
    }

    func testNothingPendingProducesNoNotice() {
        let rows = [tag("swift", new: 0)]
        XCTAssertNil(TagAcceptAllFeedback.make(before: rows, after: rows, result: CurationResult()))
    }
}
