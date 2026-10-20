import XCTest
import AppKit
import OratorCore
@testable import Orator

final class IntegrationTests: XCTestCase {
    func testTenNormalRestartsDoNotTripCircuit() throws {
        let done = expectation(description: "ten intentional restarts")
        let bridge = ProcessBridge()
        var count = 0
        func next() {
            do {
                try bridge.launch(URL(fileURLWithPath: "/bin/cat"))
                bridge.stop {
                    count += 1
                    if count == 10 { done.fulfill() } else { next() }
                }
            } catch { XCTFail("Normal restart counted as failure: \(error)"); done.fulfill() }
        }
        next()
        wait(for: [done], timeout: 15)
        XCTAssertEqual(count, 10)
    }
    func testMalformedChildOutputTerminatesProtocol() throws {
        let done = expectation(description: "invalid output handled")
        let bridge = ProcessBridge()
        bridge.onExit = { done.fulfill() }
        try bridge.launch(URL(fileURLWithPath: "/bin/sh"),
                          arguments: ["-c", "printf 'not-json\\n'; sleep 1"])
        wait(for: [done], timeout: 5)
        XCTAssertFalse(bridge.running)
        bridge.stop()
    }
    func testSplitFramesAreReassembled() throws {
        let done = expectation(description: "fragmented protocol")
        let bridge = ProcessBridge()
        bridge.onMessage = { object in
            XCTAssertEqual(object["event"] as? String, "ready")
            done.fulfill()
        }
        try bridge.launch(URL(fileURLWithPath: "/bin/sh"),
                          arguments: ["-c", "printf '{\"event\":\"'; sleep 0.05; printf 'ready\"}\\n'; sleep 1"])
        wait(for: [done], timeout: 5)
        bridge.stop()
    }
    func testOldGenerationCannotPublishToNewChild() throws {
        let done = expectation(description: "new generation")
        let bridge = ProcessBridge()
        var events: [String] = []
        bridge.onMessage = { object in
            events.append(object["event"] as? String ?? "")
            if events.last == "new" { done.fulfill() }
        }
        try bridge.launch(URL(fileURLWithPath: "/bin/sh"),
                          arguments: ["-c", "sleep 0.1; printf '{\"event\":\"old\"}\\n'"])
        try bridge.launch(URL(fileURLWithPath: "/bin/sh"),
                          arguments: ["-c", "printf '{\"event\":\"new\"}\\n'; sleep 1"])
        wait(for: [done], timeout: 5)
        XCTAssertEqual(events, ["new"])
        bridge.stop()
    }
    func testUnexpectedCrashesOpenCircuit() throws {
        let done = expectation(description: "bounded crash recovery")
        let bridge = ProcessBridge()
        var exits = 0
        func launch() {
            do {
                try bridge.launch(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 1"])
            } catch {
                XCTAssertEqual(exits, 4)
                done.fulfill()
            }
        }
        bridge.onExit = { exits += 1; launch() }
        launch()
        wait(for: [done], timeout: 8)
        XCTAssertEqual(exits, 4)
        bridge.stop()
    }
    func testStopCompletionWaitsForStubbornChildExit() throws {
        let done = expectation(description: "confirmed child exit")
        let bridge = ProcessBridge()
        bridge.onMessage = { _ in
            let pid = bridge.processID!
            bridge.stop {
                XCTAssertEqual(kill(pid, 0), -1)
                done.fulfill()
            }
        }
        try bridge.launch(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c",
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('{\"event\":\"ready\"}',flush=True); time.sleep(20)"])
        wait(for: [done], timeout: 5)
        bridge.stop()
    }
    func testTargetChangesAreRejected() {
        let element = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(getpid() + 1)
        func target(_ pid: pid_t, _ element: AXUIElement, _ range: NSRange, _ value: String) -> TargetSnapshot {
            TargetSnapshot(pid: pid, element: element, role: "AXTextField", subrole: "",
                           range: range, value: value)
        }
        let original = target(1, element, NSRange(location: 2, length: 0), "hello")
        XCTAssertTrue(original.matches(target(1, element, NSRange(location: 2, length: 0), "hello")))
        XCTAssertFalse(original.matches(target(2, element, NSRange(location: 2, length: 0), "hello")))
        XCTAssertFalse(original.matches(target(1, other, NSRange(location: 2, length: 0), "hello")))
        XCTAssertFalse(original.matches(target(1, element, NSRange(location: 3, length: 0), "hello")))
        XCTAssertFalse(original.matches(target(1, element, NSRange(location: 2, length: 0), "changed")))
    }
    private func insertingController() -> (Controller, String) {
        let controller = Controller(startServices: false)
        let id = UUID().uuidString
        controller.machine.begin(id)
        for next: Phase in [.recording, .stopping, .transcribing, .inserting] {
            controller.machine.advance(id, to: next)
        }
        controller.phase = .inserting
        return (controller, id)
    }
    func testFailureRejectsLatePasteCompletion() {
        let (controller, id) = insertingController()
        controller.fail("Simulated sleep during insertion")
        controller.complete(id, "Late success", delivered: true)
        XCTAssertEqual(controller.machine.phase, .failed)
        XCTAssertEqual(controller.machine.id, id)
        XCTAssertEqual(controller.message, "Simulated sleep during insertion")
    }
    func testUnconfirmedInsertionRemainsRecoverable() {
        let (controller, id) = insertingController()
        controller.complete(id, "Unconfirmed", delivered: false)
        XCTAssertEqual(controller.machine.phase, .failed)
        XCTAssertEqual(controller.machine.id, id)
    }
    func testCancellationRejectsLatePasteCompletion() {
        let (controller, id) = insertingController()
        controller.cancel()
        controller.complete(id, "Late success", delivered: true)
        XCTAssertEqual(controller.machine.phase, .idle)
        XCTAssertNil(controller.machine.id)
        XCTAssertNotEqual(controller.message, "Late success")
    }
    func testFnAfterFailureDoesNotActivateSettingsOrDeleteRecovery() {
        let controller = Controller(startServices: false)
        let id = UUID().uuidString
        controller.machine.begin(id)
        controller.machine.advance(id, to: .failed)
        controller.phase = .failed
        controller.microphone = true
        controller.recoveries = [Recovery(id: id)]
        controller.targetProvider = { nil }
        var activations = 0
        controller.showWindow = { activations += 1 }
        controller.keyDown()
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.recoveries.map(\.id), [id])
        XCTAssertNotNil(controller.notice)
    }
    func testFnWhenUnreadyDoesNotActivateSettings() {
        let controller = Controller(startServices: false)
        controller.microphone = true
        controller.targetProvider = { nil }
        var activations = 0
        controller.showWindow = { activations += 1 }
        controller.keyDown()
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(controller.notice?.contains("not ready") == true)
    }
    func testFnWithoutMicPermissionDoesNotOpenAWindow() {
        let controller = Controller(startServices: false)
        controller.targetProvider = { nil }
        var activations = 0
        controller.showWindow = { activations += 1 }
        controller.keyDown()
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(controller.notice?.contains("Microphone permission") == true)
    }
    func testFullRecoveryDropsEmptyRecordingsBeforeAnythingUsable() {
        let controller = Controller(startServices: false)
        var usable = Recovery(id: UUID().uuidString); usable.samples = 48000
        var empty = (0..<2).map { _ in Recovery(id: UUID().uuidString) }
        empty[0].samples = 0; empty[1].samples = 3000
        controller.recoveries = [usable] + empty
        controller.targetProvider = { nil }
        controller.keyDown()
        XCTAssertEqual(controller.recoveries.map(\.id), [usable.id])
        XCTAssertFalse(controller.notice?.contains("Recovery storage") == true)
    }
    func testFullRecoveryEvictsOldestInsteadOfBlockingDictation() {
        let controller = Controller(startServices: false)
        let saved = (0..<Controller.maxPendingRecoveries).map { index -> Recovery in
            var entry = Recovery(id: UUID().uuidString)
            entry.samples = 48000; entry.created = Date(timeIntervalSinceNow: Double(-index * 60))
            return entry
        }
        controller.recoveries = saved
        XCTAssertTrue(controller.makeRecoveryRoom())
        XCTAssertEqual(controller.recoveries.map(\.id), Array(saved.prefix(Controller.maxPendingRecoveries - 1)).map(\.id))
    }
    func testDismissingErrorNoticePreservesRecovery() {
        let controller = Controller(startServices: false)
        let id = UUID().uuidString
        controller.recoveries = [Recovery(id: id)]
        controller.showNotice("Test error")
        controller.dismissNotice()
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.recoveries.map(\.id), [id])
    }
    func testStatusPanelCannotTakeKeyboardFocus() {
        _ = NSApplication.shared
        let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
    func testReleaseDuringStartupDrainsInsteadOfCancelling() {
        let controller = Controller(startServices: false)
        var requests: [String] = []
        controller.captureRequestOverride = { request in
            requests.append(request["op"] as? String ?? ""); return true
        }
        let id = UUID().uuidString
        controller.machine.begin(id)
        controller.phase = .starting
        controller.captureReady = true
        controller.stopRecording()
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertEqual(controller.machine.id, id)
        XCTAssertEqual(requests, ["stop"])
        XCTAssertTrue(controller.captureReady)
        controller.captureMessage(["event": "recording", "id": id])
        XCTAssertEqual(controller.phase, .stopping)
        controller.captureMessage(["event": "stopped", "id": id, "samples": 0])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(controller.notice)
        XCTAssertTrue(controller.notice?.contains("No audio captured") == true)
    }
    func testMicrophoneReadinessUsesCaptureProcessStatus() {
        let controller = Controller(startServices: false)
        controller.microphone = true
        controller.captureMessage(["event": "permissions", "microphone": "denied"])
        XCTAssertFalse(controller.microphone)
        XCTAssertEqual(controller.captureMicrophoneStatus, "denied")
        controller.captureMessage(["event": "permissions", "microphone": "authorized"])
        XCTAssertTrue(controller.microphone)
    }
    private func readyController(_ requests: @escaping (String) -> Void) -> Controller {
        let controller = Controller(startServices: false)
        controller.microphone = true; controller.modelReady = true; controller.captureReady = true
        controller.targetProvider = { nil }
        controller.captureRequestOverride = { request in requests(request["op"] as? String ?? ""); return true }
        return controller
    }
    func testQuickTapIsDiscardedWithoutTranscription() {
        var requests: [String] = []
        let controller = readyController { requests.append($0) }
        controller.keyDown()
        XCTAssertEqual(controller.phase, .starting)
        controller.keyUp()
        XCTAssertEqual(controller.phase, .starting)
        let done = expectation(description: "debounce elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalkGesture.debounce + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(requests, ["start", "cancel"])
    }
    func testDoubleTapLocksHandsFreeUntilNextPress() {
        var requests: [String] = []
        let controller = readyController { requests.append($0) }
        controller.keyDown(); controller.keyUp(); controller.keyDown()
        XCTAssertTrue(controller.handsFree)
        controller.keyUp()
        XCTAssertEqual(controller.phase, .starting)
        controller.keyDown()
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertFalse(controller.handsFree)
        XCTAssertEqual(requests, ["start", "stop"])
    }
    func testChordWhileStartingCancels() {
        var requests: [String] = []
        let controller = readyController { requests.append($0) }
        controller.keyDown()
        controller.chordDuringStart()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(requests, ["start", "cancel"])
    }
    func testEscapeWhileRecordingCanBeUndone() {
        var requests: [String] = []
        let controller = readyController { requests.append($0) }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        controller.cancelWithUndo()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(requests, ["start", "stop"])
        XCTAssertFalse(controller.undoAvailable)
        controller.captureMessage(["event": "stopped", "id": id, "samples": 32000, "silent": false])
        XCTAssertTrue(controller.undoAvailable)
        controller.expireUndo()
        XCTAssertFalse(controller.undoAvailable)
    }
    func testSilentCancelledRecordingOffersNoUndo() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        controller.cancelWithUndo()
        controller.captureMessage(["event": "stopped", "id": id, "samples": 32000, "silent": true])
        XCTAssertFalse(controller.undoAvailable)
    }
    func testDigitalSilenceIsReportedInsteadOfTranscribed() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        controller.captureMessage(["event": "silent", "id": id, "silent": true])
        XCTAssertNotNil(controller.recordingHint)
        controller.stopRecording()
        controller.captureMessage(["event": "stopped", "id": id, "samples": 32000, "silent": true])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.notice?.contains("only silence") == true)
    }
    func testReleaseAfterFailedSessionStopsRecording() {
        var requests: [String] = []
        let controller = readyController { requests.append($0) }
        let old = UUID().uuidString
        controller.machine.begin(old); _ = controller.machine.advance(old, to: .failed); controller.publish()
        XCTAssertEqual(controller.phase, .failed)
        controller.keyDown()
        XCTAssertEqual(controller.phase, .starting)
        let held = expectation(description: "held past the tap window")
        DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalkGesture.debounce + 0.1) { held.fulfill() }
        wait(for: [held], timeout: 3)
        controller.keyUp()
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertEqual(requests, ["start", "stop"])
    }
    func testClosedLidWithBuiltInMicIsExplained() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id, "transport": "builtIn", "clamshell": true])
        XCTAssertTrue(controller.recordingHint?.contains("lid") == true)
        controller.stopRecording()
        controller.captureMessage(["event": "stopped", "id": id, "samples": 32000, "silent": true])
        XCTAssertTrue(controller.notice?.contains("lid is closed") == true)
        XCTAssertEqual(controller.noticeAction?.label, "Settings")
    }
    func testExternalMicWithClosedLidIsNotFlagged() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id, "transport": "usb", "clamshell": true])
        XCTAssertNil(controller.recordingHint)
    }
    func testVocabularySuggestionAddsOnlyNewReplacements() {
        let controller = Controller(startServices: false)
        controller.settings.replacements = [Replacement(from: "orater", to: "Orator")]
        controller.suggest([Replacement(from: "orater", to: "Orator"), Replacement(from: "kubernetes", to: "Kubernetes")])
        XCTAssertEqual(controller.noticeAction?.label, "Add")
        controller.noticeAction?.run()
        XCTAssertEqual(controller.settings.replacements.map(\.from), ["orater", "kubernetes"])
    }
    func testHudFollowsHotkeyAndTranscriptionOnly() {
        let controller = Controller(startServices: false)
        for (phase, visible) in [(Phase.starting, true), (.recording, true), (.stopping, true), (.transcribing, true),
                                 (.inserting, false), (.idle, false), (.failed, false)] {
            controller.phase = phase
            XCTAssertEqual(controller.hudPhase, visible, "\(phase)")
        }
    }
    func testSuccessfulDictationTipDoesNotOpenAPopup() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        controller.stopRecording()
        _ = controller.machine.advance(id, to: .transcribing); _ = controller.machine.advance(id, to: .inserting)
        controller.complete(id, "Text inserted and verified.", delivered: true)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.phase, .idle)
    }
    func testListeningCueWaitsForRealAudio() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(controller.micLive)
        XCTAssertEqual(controller.message, "Starting")
        controller.captureMessage(["event": "live", "id": id, "warmup": 0.6])
        XCTAssertTrue(controller.micLive)
        XCTAssertEqual(controller.message, "Listening")
    }
    func testListeningCueFallsBackWhenMicNeverGoesLive() {
        let controller = readyController { _ in }
        controller.keyDown()
        guard let id = controller.machine.id else { return XCTFail("No session") }
        controller.captureMessage(["event": "recording", "id": id])
        let waited = expectation(description: "fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { waited.fulfill() }
        wait(for: [waited], timeout: 3)
        XCTAssertTrue(controller.micLive)
    }
    func testTargetIsReadAfterCaptureStarts() {
        var order: [String] = []
        let controller = readyController { order.append($0) }
        controller.targetProvider = { order.append("target"); return nil }
        controller.keyDown()
        XCTAssertEqual(order, ["start", "target"])
    }
}
