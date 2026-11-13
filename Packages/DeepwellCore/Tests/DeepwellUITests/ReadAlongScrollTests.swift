import XCTest
@testable import DeepwellUI

/// Read-along used to scroll to the bottom of the article because the word's y was a fraction of a frame as tall
/// as the whole article. The target follows the block that is actually being spoken.
final class ReadAlongScrollTests: XCTestCase {
    private let content: CGFloat = 12_000
    private let viewport: CGFloat = 800
    private var end: CGFloat { content - viewport }

    func testAnEarlyWordStaysNearTheTop() {
        let target = ReadAlongScroll.followTarget(
            blockMinY: 480, blockHeight: 220, wordFraction: 0.1,
            contentHeight: content, viewport: viewport, currentOffset: 0, force: true)
        let wordY = 480 + 0.1 * 220
        XCTAssertEqual(target!, wordY - viewport * ReadAlongScroll.settle, accuracy: 0.5)
        XCTAssertLessThan(target!, 1_000)
        XCTAssertLessThan(target!, end - 1_000)
    }

    func testAFrameTheSizeOfTheArticleDoesNotJumpToTheEnd() {
        // The old background GeometryReader: origin at the top, height of the whole article, fraction near the end.
        let target = ReadAlongScroll.followTarget(
            blockMinY: 0, blockHeight: content, wordFraction: 0.95,
            contentHeight: content, viewport: viewport, currentOffset: 0, force: true)
        XCTAssertNil(target)
        XCTAssertNil(ReadAlongScroll.wordY(blockMinY: 0, blockHeight: content, wordFraction: 0.95, contentHeight: content))
    }

    func testTheTargetFollowsTheWordDownTheArticle() {
        let first = ReadAlongScroll.followTarget(
            blockMinY: 480, blockHeight: 220, wordFraction: 0.1,
            contentHeight: content, viewport: viewport, currentOffset: 0, force: true)!
        // Still inside the comfortable band: no scroll, so it does not march toward the end.
        let settledWord = first + viewport * 0.40
        XCTAssertNil(ReadAlongScroll.targetOffset(
            wordY: settledWord, viewport: viewport, contentHeight: content, currentOffset: first, force: false))

        // The word has left the bottom of the band. The next offset follows it, and is nowhere near the end.
        let laterWord = first + viewport * ReadAlongScroll.bandBottom + 40
        let later = ReadAlongScroll.targetOffset(
            wordY: laterWord, viewport: viewport, contentHeight: content, currentOffset: first, force: false)
        XCTAssertEqual(later!, laterWord - viewport * ReadAlongScroll.settle, accuracy: 0.5)
        XCTAssertGreaterThan(later!, first)
        XCTAssertLessThan(later!, end - 5_000)
    }

    func testAWordNearTheEndMayReachTheEnd() {
        let target = ReadAlongScroll.followTarget(
            blockMinY: content - 160, blockHeight: 140, wordFraction: 0.8,
            contentHeight: content, viewport: viewport, currentOffset: 0, force: true)
        XCTAssertEqual(target!, end, accuracy: 0.5)
    }

    func testAFractionPastTheBlockStaysAtTheBottomOfThatBlock() {
        let y = ReadAlongScroll.wordY(blockMinY: 480, blockHeight: 220, wordFraction: 30, contentHeight: content)
        XCTAssertEqual(y!, 700, accuracy: 0.1)
        let target = ReadAlongScroll.targetOffset(wordY: y!, viewport: viewport, contentHeight: content, currentOffset: 0, force: true)
        XCTAssertLessThan(target!, 1_000)
    }

    func testUnusableMeasurementsDoNotProduceAnOffset() {
        XCTAssertNil(ReadAlongScroll.wordY(blockMinY: 10, blockHeight: .infinity, wordFraction: 0.2, contentHeight: content))
        XCTAssertNil(ReadAlongScroll.wordY(blockMinY: .nan, blockHeight: 200, wordFraction: 0.2, contentHeight: content))
        XCTAssertNil(ReadAlongScroll.targetOffset(wordY: .nan, viewport: viewport, contentHeight: content, currentOffset: 0, force: true))
        XCTAssertNil(ReadAlongScroll.targetOffset(wordY: 400, viewport: 0, contentHeight: content, currentOffset: 0, force: true))
    }
}
