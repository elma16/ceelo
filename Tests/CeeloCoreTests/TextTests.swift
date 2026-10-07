import XCTest
@testable import CeeloCore

final class TextTests: XCTestCase {
    func testNormalizeLowercasesAndDropsPunctuationAndSymbols() {
        XCTAssertEqual(normalizeText("  Heads-up!!  New   TICKET, please. "), "heads up new ticket please")
        XCTAssertEqual(normalizeText("soft_bell"), "soft bell")
        XCTAssertEqual(normalizeText("Café"), "café")
        XCTAssertEqual(normalizeText("?!"), "")
    }

    func testNumberWordsBecomeDigits() {
        XCTAssertEqual(normalizeText("Fifteen"), "15")
        XCTAssertEqual(normalizeText("It costs £15"), "it costs 15")
        XCTAssertEqual(normalizeText("twenty-one and twenty"), "21 and 20")
        XCTAssertEqual(normalizeText("ninety nine, zero, nineteen"), "99 0 19")
        XCTAssertEqual(normalizeText("forty zero"), "40 0", "zero doesn't combine with tens")
        XCTAssertEqual(normalizeText("one hundred"), "1 hundred", "only numbers below 100")
    }

    func testEditDistance() {
        XCTAssertTrue(withinEditDistance("favorite", "favourite", maxDistance: 1))
        XCTAssertTrue(withinEditDistance("cat", "cats", maxDistance: 1))
        XCTAssertFalse(withinEditDistance("cat", "dog", maxDistance: 2))
        XCTAssertFalse(withinEditDistance("cat", "bat", maxDistance: 0))
        XCTAssertTrue(withinEditDistance("", "ab", maxDistance: 2))
        XCTAssertFalse(withinEditDistance("", "abc", maxDistance: 2))
        XCTAssertFalse(withinEditDistance("abc", "", maxDistance: 2))
        XCTAssertFalse(withinEditDistance("a", "abcd", maxDistance: 2))
        XCTAssertFalse(withinEditDistance("abcdef", "uvwxyz", maxDistance: 2), "gives up once every row is too far")
    }

    func testWordToleranceByMode() {
        XCTAssertTrue(wordsMatch("favourite", "favorite", mode: .words))
        XCTAssertFalse(wordsMatch("kissing", "missing", mode: .words), "7 letters must match exactly")
        XCTAssertTrue(wordsMatch("kissing", "missing", mode: .fuzzy))
        XCTAssertTrue(wordsMatch("yuda", "yoda", mode: .fuzzy))
        XCTAssertFalse(wordsMatch("yuda", "yoda", mode: .words))
        XCTAssertTrue(wordsMatch("hospitle", "hospital", mode: .fuzzy))
        XCTAssertFalse(wordsMatch("cat", "bat", mode: .fuzzy), "3 letters must match exactly")
        XCTAssertFalse(wordsMatch("epically", "epic", mode: .contains))
    }

    func testPhraseMatching() {
        func first(_ phrase: String, in text: String, _ mode: MatchMode) -> Int? {
            let normalized = normalizeText(text)
            return Phrase(phrase).firstMatch(in: tokenize(normalized), normalized: normalized, mode: mode)
        }
        XCTAssertEqual(first("new ticket", in: "a new ticket and a new ticket", .words), 1)
        XCTAssertNil(first("new ticket", in: "new tickets", .words))
        XCTAssertNil(first("new ticket", in: "new", .words))
        XCTAssertEqual(first("ticket", in: "two new tickets", .contains), 2)
        XCTAssertEqual(first("epic", in: "epically", .contains), 0)
        XCTAssertNil(first("epic", in: "nothing here", .contains))
        XCTAssertEqual(first("yoda", in: "yuda says hi", .fuzzy), 0)
        XCTAssertNil(first("?", in: "anything", .words))
    }
}
