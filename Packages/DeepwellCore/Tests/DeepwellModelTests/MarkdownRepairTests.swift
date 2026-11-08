import XCTest
@testable import DeepwellModel

final class MarkdownRepairTests: XCTestCase {
    func testSubstackLinkedImageUsesFullSizeHrefWhenSrcIsBroken() {
        let md = """
        Intro.

        [

        ![Flow diagram](https://www.lighthousenewsletter.com/p/fl_progressive:steep/https%3A%2F%2Fx%2Fa_1400x400.avif)

        ](https://substackcdn.com/image/fetch/$s_!TXCo!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fx%2Fa_1400x400.avif)

        After.
        """
        let out = MarkdownRepair.repair(md)
        XCTAssertTrue(out.contains("![Flow diagram](https://substackcdn.com/image/fetch/$s_!TXCo!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fx%2Fa_1400x400.avif)"), out)
        XCTAssertFalse(out.contains("lighthousenewsletter.com/p/fl_"))
        XCTAssertTrue(out.hasPrefix("Intro.") && out.hasSuffix("After."))
    }

    func testLinkedImageToAPageKeepsTheImageSrc() {
        let out = MarkdownRepair.repair("[![Cover](https://x.com/c.png)](https://x.com/article)")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "![Cover](https://x.com/c.png)")
    }

    func testEscapedHashnodeImageWithAutolinkedURL() {
        let md = #"!\[Four skill shapes: specialist (one deep bar), owner (many dives\]([https://cdn.hashnode.com/u/b16.png](https://cdn.hashnode.com/u/b16.png) align="middle")"#
        XCTAssertEqual(MarkdownRepair.repair(md),
                       "![Four skill shapes: specialist (one deep bar), owner (many dives](https://cdn.hashnode.com/u/b16.png)")
    }

    func testOrdinaryTextAndLinksAreUntouched() {
        let md = "A [link](https://x.com) and ![img](https://x.com/a.png).\n\n- [item](https://y.com)"
        XCTAssertEqual(MarkdownRepair.repair(md), md)
    }
}

final class MarkdownRepairMoreTests: XCTestCase {
    func testSplitSubstackSourceIsDecodedToTheOriginalImage() {
        let md = "![X avatar for @paulg](https://www.noahpinion.blog/p/fl_progressive:steep/https%3A%2F%2Fpbs.substack.com%2Fprofile_images%2F1%2Fa_normal.jpg)"
        XCTAssertEqual(MarkdownRepair.repair(md), "![X avatar for @paulg](https://pbs.substack.com/profile_images/1/a_normal.jpg)")
    }

    func testTweetCardLinkKeepsContentAndDropsBracketLines() {
        let md = "Before.\n\n[\n\n![X avatar](https://pbs.twimg.com/a.jpg)\n\nPaul Graham@paulg\n\nA tweet.\n\n](https://x.com/paulg/status/1)\n\nAfter."
        let out = MarkdownRepair.repair(md)
        XCTAssertFalse(out.components(separatedBy: "\n").contains("["), out)
        XCTAssertFalse(out.contains("](https://x.com/paulg/status/1)"), out)
        XCTAssertTrue(out.contains("![X avatar](https://pbs.twimg.com/a.jpg)") && out.contains("A tweet."))
    }
}

final class MarkdownRepairChainTests: XCTestCase {
    func testBackToBackTweetCardsLeaveNoBracketLines() {
        let md = "[\n\nTweet one.\n\n](https://x.com/a/status/1)[\n\nTweet two.\n\n](https://x.com/b/status/2)[](https://x.com/c/status/3)\n\nAfter."
        XCTAssertEqual(MarkdownRepair.repair(md).components(separatedBy: "\n").filter { !$0.isEmpty }, ["Tweet one.", "Tweet two.", "After."])
    }
}
