import XCTest
import DeepwellModel
@testable import DeepwellNarration

final class DuplicateTitleTests: XCTestCase {
    func testNightwatchmanTitleIsSpokenOnlyInIntro() {
        let item = Item(type: .magazineArticle, title: "100% human written", author: "Scott Oliver")
        let script = NarrationScript.build(item: item,
            body: "100% human written\n\nScott Oliver rages against the machine.\n\nThe story begins.",
            pronunciations: [:], model: "test", voice: "test")
        XCTAssertFalse(script.words.contains { $0.written == "100%" && $0.location != nil })
        XCTAssertTrue(script.words.contains { $0.written == "Scott" && $0.location?.block == 0 })
    }
}
