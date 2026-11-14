import XCTest
@testable import DeepwellModel

final class ArticleTitleTests: XCTestCase {
    func testSuppressesExtractedTitleInExistingMagazineBody() {
        XCTAssertEqual(ArticleBlocks.blocks(for: "100% human written\n\nScott Oliver rages against the machine.", title: "100% human written"),
                       [.paragraph("Scott Oliver rages against the machine.")])
    }

    func testMatchesInlineFormattingAndWhitespace() {
        XCTAssertEqual(ArticleBlocks.blocks(for: "# **Human written**\n\nStory.", title: "Human   written"), [.paragraph("Story.")])
    }

    func testPreservesNonmatchingOpeningAndLaterTitleReferences() {
        let md = "Opening paragraph.\n\n# Human written\n\nStory."
        XCTAssertEqual(ArticleBlocks.blocks(for: md, title: "Human written"), ArticleBlocks.blocks(for: md))
        XCTAssertEqual(ArticleBlocks.blocks(for: "Human written is the title.\n\nStory.", title: "Human written").count, 2)
    }
}
