import XCTest
@testable import OratorCore

final class SmartTextTests: XCTestCase {
    func testEmptyFieldKeepsSentence() {
        XCTAssertEqual(SmartText.adapt("Hello there.", before: "", after: ""), "Hello there.")
    }
    func testAfterSentenceAddsSpaceAndKeepsCapital() {
        XCTAssertEqual(SmartText.adapt("Next one.", before: "Done.", after: ""), " Next one.")
        XCTAssertEqual(SmartText.adapt("Next one.", before: "Done. ", after: ""), "Next one.")
    }
    func testMidSentenceLowercasesAndSpaces() {
        XCTAssertEqual(SmartText.adapt("Tomorrow morning.", before: "Let's meet", after: ""), " tomorrow morning.")
        XCTAssertEqual(SmartText.adapt("Tomorrow morning.", before: "Let's meet, ", after: ""), "tomorrow morning.")
    }
    func testPronounAndAcronymsKeepCapitals() {
        XCTAssertEqual(SmartText.adapt("I think so.", before: "and", after: ""), " I think so.")
        XCTAssertEqual(SmartText.adapt("I'm in.", before: "and ", after: ""), "I'm in.")
        XCTAssertEqual(SmartText.adapt("NASA launched.", before: "then ", after: ""), "NASA launched.")
        XCTAssertEqual(SmartText.adapt("iPhone works.", before: "the ", after: ""), "iPhone works.")
    }
    func testInsertingBeforeWordsDropsPeriodAndSeparates() {
        XCTAssertEqual(SmartText.adapt("Really.", before: "It is ", after: "good"), "really ")
        XCTAssertEqual(SmartText.adapt("Wait...", before: "", after: "now"), "Wait... ")
    }
    func testNewlineIsABoundary() {
        XCTAssertEqual(SmartText.adapt("New line.", before: "Title\n", after: ""), "New line.")
    }
    func testOpeningBracketsAndHandlesDoNotGetSpace() {
        XCTAssertEqual(SmartText.adapt("Note.", before: "(", after: ")"), "note.")
        XCTAssertEqual(SmartText.adapt("Alex.", before: "@", after: ""), "alex.")
    }
    func testPunctuationLeadingTextIsNotSpaced() {
        XCTAssertEqual(SmartText.adapt(", and more.", before: "this", after: ""), ", and more.")
    }
    func testWhitespaceOnlyTranscriptIsUnchanged() {
        XCTAssertEqual(SmartText.adapt("  ", before: "x", after: "y"), "  ")
    }
}
