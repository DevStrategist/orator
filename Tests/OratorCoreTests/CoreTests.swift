import XCTest
@testable import OratorCore

final class CoreTests: XCTestCase {
    func testCompleteSession() {
        var state = SessionMachine(); let id = UUID().uuidString
        XCTAssertTrue(state.begin(id))
        for next: Phase in [.recording, .stopping, .transcribing, .inserting, .idle] {
            XCTAssertTrue(state.advance(id, to: next))
        }
        XCTAssertNil(state.id)
    }
    func testRejectDoubleStart() {
        var state = SessionMachine()
        XCTAssertTrue(state.begin(UUID().uuidString))
        XCTAssertFalse(state.begin(UUID().uuidString))
    }
    func testRejectInvalidIdentity() {
        var state = SessionMachine()
        for value in ["", "../escape", "not-a-uuid"] { XCTAssertFalse(state.begin(value)) }
    }
    func testStaleCallbacksAtEveryPhase() {
        var state = SessionMachine(); let id = UUID().uuidString
        state.begin(id)
        for next: Phase in [.recording, .stopping, .transcribing, .inserting, .idle] {
            XCTAssertFalse(state.advance(UUID().uuidString, to: next))
            XCTAssertTrue(state.advance(id, to: next))
        }
    }
    func testDuplicateTransitions() {
        var state = SessionMachine(); let id = UUID().uuidString
        state.begin(id)
        XCTAssertTrue(state.advance(id, to: .recording))
        XCTAssertFalse(state.advance(id, to: .recording))
        XCTAssertFalse(state.advance(id, to: .idle))
    }
    func testCancelInvalidatesLateResults() {
        for stop: Phase in [.starting, .recording, .stopping, .transcribing, .inserting] {
            var state = SessionMachine(); let id = UUID().uuidString
            state.begin(id)
            for phase: Phase in [.recording, .stopping, .transcribing, .inserting] {
                if state.phase == stop { break }
                state.advance(id, to: phase)
            }
            state.cancel()
            XCTAssertEqual(state.phase, .idle)
            XCTAssertFalse(state.advance(id, to: .inserting))
        }
    }
    func testFailedRecordingCanRetry() {
        var state = SessionMachine(); let id = UUID().uuidString
        state.begin(id)
        XCTAssertTrue(state.advance(id, to: .failed))
        XCTAssertTrue(state.advance(id, to: .transcribing))
    }
    func testStopWhileStarting() {
        var state = SessionMachine(); let id = UUID().uuidString
        state.begin(id)
        XCTAssertTrue(state.advance(id, to: .stopping))
        XCTAssertFalse(state.advance(id, to: .recording))
    }
    func testHotkeyValidation() {
        XCTAssertTrue(Hotkey().isValid)
        XCTAssertFalse(Hotkey(keyCode: 0, modifiers: 0, label: "A").isValid)
        XCTAssertFalse(Hotkey(keyCode: 49, modifiers: 1 << 20, label: "Cmd Space").isValid)
        XCTAssertFalse(Hotkey(keyCode: 51, modifiers: 1 << 20, label: "Cmd Delete").isValid)
        XCTAssertFalse(Hotkey(keyCode: 200, modifiers: 1 << 18, label: "?").isValid)
        XCTAssertTrue(Hotkey(keyCode: -1, modifiers: 1 << 19, label: "Option").isValid)
    }
    func testKeyRepeatAndDuplicateRelease() {
        var key = KeyLatch()
        XCTAssertEqual(key.update(down: true, matches: true), true)
        XCTAssertNil(key.update(down: true, matches: true, isRepeat: true))
        XCTAssertNil(key.update(down: true, matches: true))
        XCTAssertEqual(key.update(down: false, matches: false), false)
        XCTAssertNil(key.update(down: false, matches: false))
    }
    func testMismatchedChordAndReset() {
        var key = KeyLatch()
        XCTAssertNil(key.update(down: true, matches: false))
        _ = key.update(down: true, matches: true)
        key.reset()
        XCTAssertFalse(key.pressed)
    }
    func testSettingsRoundTrip() throws {
        var settings = Settings()
        settings.toggleMode = true
        settings.replacements = [.init(from: "orater", to: "Orator")]
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(settings, decoded)
    }
    func testSettingsFromOlderBuildKeepShortcutAndGainDefaults() throws {
        let saved = #"{"sounds":false,"autoInsert":true,"toggleMode":false,"hotkey":{"label":"Fn","keyCode":-1,"modifiers":8388608},"preserveClipboard":true,"maxSeconds":300,"neverStore":false,"microphoneUID":"","modelPath":"","replacements":[]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(saved.utf8))
        XCTAssertTrue(settings.hotkey.isFnOnly)
        XCTAssertFalse(settings.sounds)
        XCTAssertTrue(settings.smartFormatting)
        XCTAssertTrue(settings.pasteWithoutCursor)
        XCTAssertFalse(settings.muteWhileDictating)
    }
    func testSettingsWithOneMalformedFieldKeepOthers() throws {
        let saved = #"{"sounds":"loud","hotkey":{"label":"Fn","keyCode":-1,"modifiers":8388608}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(saved.utf8))
        XCTAssertTrue(settings.hotkey.isFnOnly)
        XCTAssertTrue(settings.sounds)
    }
    func testSettingsBounds() {
        var settings = Settings(); settings.maxSeconds = -100; settings.validate()
        XCTAssertEqual(settings.maxSeconds, 10)
        settings.maxSeconds = Int.max; settings.validate()
        XCTAssertEqual(settings.maxSeconds, 1200)
        settings.replacements = (0..<250).map { .init(from: "\($0)", to: "") }
        settings.validate(); XCTAssertEqual(settings.replacements.count, 200)
    }
    func testLiteralReplacements() {
        var settings = Settings()
        settings.replacements = [.init(from: "a.b", to: "correct"), .init(from: "", to: "bad")]
        XCTAssertEqual(settings.transform("a.b A.B"), "correct A.B")
    }
    func testFragmentedProtocol() throws {
        var parser = JSONLineBuffer()
        XCTAssertTrue(try parser.append(Data("{\"event\":\"re".utf8)).isEmpty)
        let messages = try parser.append(Data("ady\"}\n{\"event\":\"level\"}\n".utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["event"] as? String, "ready")
    }
    func testProtocolRejectsInvalidAndOversized() {
        var parser = JSONLineBuffer(limit: 32)
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: 33)))
        var invalid = JSONLineBuffer()
        XCTAssertThrowsError(try invalid.append(Data("not-json\n".utf8)))
        var array = JSONLineBuffer()
        XCTAssertThrowsError(try array.append(Data("[]\n".utf8)))
    }
    func testUnicodeProtocol() throws {
        var parser = JSONLineBuffer()
        let result = try parser.append(Data("{\"text\":\"你好 👋\"}\n".utf8))
        XCTAssertEqual(result.first?["text"] as? String, "你好 👋")
    }
    func testClipboardOwnership() {
        XCTAssertTrue(PastePolicy.canRestore(ownedCount: 3, currentCount: 3, ownedID: "a", currentID: "a"))
        XCTAssertFalse(PastePolicy.canRestore(ownedCount: 3, currentCount: 4, ownedID: "a", currentID: "a"))
        XCTAssertFalse(PastePolicy.canRestore(ownedCount: 3, currentCount: 3, ownedID: "a", currentID: "b"))
        XCTAssertFalse(PastePolicy.canRestore(ownedCount: 3, currentCount: 3, ownedID: "a", currentID: nil))
    }
    func testTerminalPayloadCannotSubmitOrTriggerControlKeys() {
        XCTAssertTrue(PastePolicy.safePayload("single line words", terminal: true))
        for text in ["command\n", "command\r", "a\tb", "\u{1b}[200~", "a\u{2028}b"] {
            XCTAssertFalse(PastePolicy.safePayload(text, terminal: true))
        }
        XCTAssertTrue(PastePolicy.safePayload("paragraph one\nparagraph two", terminal: false))
        XCTAssertFalse(PastePolicy.safePayload("a\0b", terminal: false))
    }
    func testExpectedEditUnicode() {
        XCTAssertEqual(PastePolicy.expectedEdit(before: "Hi 👋 there", range: NSRange(location: 3, length: 2),
                                               inserted: "世界"), "Hi 世界 there")
        XCTAssertEqual(PastePolicy.expectedEdit(before: "abc", range: NSRange(location: 1, length: 0),
                                               inserted: "X"), "aXbc")
        XCTAssertNil(PastePolicy.expectedEdit(before: "abc", range: NSRange(location: 4, length: 0), inserted: "X"))
        XCTAssertNil(PastePolicy.expectedEdit(before: "abc", range: NSRange(location: 1, length: Int.max), inserted: "X"))
    }
    func testRecoveryMetadataRoundTrip() throws {
        let recovery = Recovery(id: UUID().uuidString)
        let decoded = try JSONDecoder().decode(Recovery.self, from: JSONEncoder().encode(recovery))
        XCTAssertEqual(recovery.id, decoded.id)
        XCTAssertEqual(decoded.sampleRate, 16000)
    }
    func testNormalRestartsDoNotConsumeFailureBudget() {
        var budget = RestartBudget()
        for now in 0..<100 { XCTAssertTrue(budget.canStart(now: Double(now) / 10)) }
    }
    func testCrashLoopOpensCircuitAndExpires() {
        var budget = RestartBudget()
        for now in 0..<4 { budget.recordFailure(now: Double(now)) }
        XCTAssertFalse(budget.canStart(now: 4))
        XCTAssertTrue(budget.canStart(now: 61))
    }
    func testRecoveryExpiresAndRemovesBothFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        var recovery = Recovery(id: id)
        recovery.created = Date(timeIntervalSince1970: 100)
        try JSONEncoder().encode(recovery).write(to: root.appendingPathComponent(id + ".json"))
        try Data([0, 0]).write(to: root.appendingPathComponent(id + ".pcm"))
        XCTAssertEqual(OratorPaths.recoveries(now: Date(timeIntervalSince1970: 86499), directory: root).count, 1)
        XCTAssertTrue(OratorPaths.recoveries(now: Date(timeIntervalSince1970: 86500), directory: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".pcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".json").path))
    }
    func testCorruptRecoveryAlsoExpires() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let manifest = root.appendingPathComponent(id + ".json")
        try Data("corrupt".utf8).write(to: manifest)
        try Data([0, 0]).write(to: root.appendingPathComponent(id + ".pcm"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                             ofItemAtPath: manifest.path)
        XCTAssertTrue(OratorPaths.recoveries(now: Date(timeIntervalSince1970: 86500), directory: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".pcm").path))
    }
}
