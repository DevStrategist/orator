import XCTest
@testable import OratorCore

final class AssistanceTests: XCTestCase {
    func testCorrectedWordBecomesSuggestion() {
        let pairs = EditLearning.corrections(inserted: "Ship the orater build today.", edited: "Ship the Orator build today.")
        XCTAssertEqual(pairs.map(\.from), ["orater"])
        XCTAssertEqual(pairs.map(\.to), ["Orator"])
    }
    func testCapitalizationFixIsLearned() {
        XCTAssertEqual(EditLearning.corrections(inserted: "ask kubernetes", edited: "ask Kubernetes").map(\.to), ["Kubernetes"])
    }
    func testRewritesAndUnrelatedWordsAreIgnored() {
        XCTAssertTrue(EditLearning.corrections(inserted: "see you soon", edited: "see you tomorrow morning").isEmpty)
        XCTAssertTrue(EditLearning.corrections(inserted: "the cat sat", edited: "the elephant sat").isEmpty)
        XCTAssertTrue(EditLearning.corrections(inserted: "same text", edited: "same text").isEmpty)
        XCTAssertTrue(EditLearning.corrections(inserted: "a b", edited: "x y").isEmpty)
    }
    func testPunctuationEditsAreNotCorrections() {
        XCTAssertTrue(EditLearning.corrections(inserted: "Hello there.", edited: "Hello there!").isEmpty)
    }
    func testEditedRegionNeedsUntouchedSurroundings() {
        XCTAssertEqual(EditLearning.editedRegion(prefix: "Dear ", suffix: "\nBye", current: "Dear Ana, hi\nBye"), "Ana, hi")
        XCTAssertNil(EditLearning.editedRegion(prefix: "Dear ", suffix: "\nBye", current: "Hi Ana\nBye"))
        XCTAssertEqual(EditLearning.editedRegion(prefix: "😀 ", suffix: "", current: "😀 ok"), "ok")
        XCTAssertNil(EditLearning.editedRegion(prefix: "abc", suffix: "bcd", current: "abcd"))
    }
    func testAudioQuality() {
        let clean = Array(repeating: 0.001, count: 20) + Array(repeating: 0.05, count: 20)
        XCTAssertEqual(AudioQuality.assess(clean)?.poor, false)
        let noisy = Array(repeating: 0.03, count: 20) + Array(repeating: 0.05, count: 20)
        XCTAssertEqual(AudioQuality.assess(noisy)?.poor, true)
        let quiet = Array(repeating: 0.0001, count: 20) + Array(repeating: 0.002, count: 20)
        XCTAssertEqual(AudioQuality.assess(quiet)?.poor, true)
        XCTAssertNil(AudioQuality.assess([0.1, 0.2]))
    }
    func testCapsLockIsAValidSingleKeyShortcutWithoutTapEdges() {
        XCTAssertTrue(Hotkey.capsLock.isValid)
        XCTAssertFalse(Hotkey(keyCode: 57, modifiers: 1 << 20, label: "⌘⇪").isValid)
        let edge = ShortcutPolicy.edges(binding: .capsLock, kind: .flags, keyCode: 57, modifiers: 1 << 16)
        XCTAssertFalse(edge.starts || edge.ends)
    }
    func testPauseAndMuteAreExclusive() {
        var settings = Settings()
        settings.muteWhileDictating = true; settings.pauseMediaWhileDictating = true
        settings.validate()
        XCTAssertFalse(settings.muteWhileDictating)
        XCTAssertTrue(settings.pauseMediaWhileDictating)
    }
    func testRemoteViewers() {
        XCTAssertTrue(RemoteViewers.contains("com.realvnc.vncviewer"))
        XCTAssertFalse(RemoteViewers.contains("com.apple.TextEdit"))
    }
}
