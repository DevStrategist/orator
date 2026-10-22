import AppKit
import XCTest
import OratorCore
@testable import Orator

final class HotkeysTests: XCTestCase {
    private let fn = Hotkey(keyCode: -1, modifiers: 1 << 23, label: "Fn")

    private func fnPress(_ keys: Hotkeys) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        event.flags = .maskSecondaryFn
        _ = keys.handle(.flagsChanged, event)
    }
    private func drainCallbacks() {
        let done = expectation(description: "keyboard callbacks delivered")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    func testQueuedPressCannotCrossSleepAndWake() {
        let keys = Hotkeys()
        keys.configure(fn, active: false, paused: false)
        var presses = 0
        keys.onDown = { presses += 1 }
        fnPress(keys)
        keys.configure(fn, active: false, paused: true)
        keys.didWake()
        keys.configure(fn, active: false, paused: false)
        drainCallbacks()
        XCTAssertEqual(presses, 0)
        fnPress(keys)
        drainCallbacks()
        XCTAssertEqual(presses, 1)
    }
    func testShortcutChangeInvalidatesQueuedPress() {
        let keys = Hotkeys()
        keys.configure(fn, active: false, paused: false)
        var presses = 0
        keys.onDown = { presses += 1 }
        fnPress(keys)
        keys.configure(Hotkey(), active: false, paused: false)
        drainCallbacks()
        XCTAssertEqual(presses, 0)
    }
    func testStoppingInvalidatesQueuedPress() {
        let keys = Hotkeys()
        keys.configure(fn, active: false, paused: false)
        var presses = 0
        keys.onDown = { presses += 1 }
        fnPress(keys)
        keys.stop()
        drainCallbacks()
        XCTAssertEqual(presses, 0)
    }
    func testMouseShortcutDeliversOnePressAndRelease() {
        let keys = Hotkeys()
        keys.configure(Hotkey(keyCode: 130, modifiers: 0, label: "Mouse 3"), active: false, paused: false)
        var transitions: [String] = []
        keys.onDown = { transitions.append("down") }
        keys.onUp = { transitions.append("up") }
        for type: CGEventType in [.otherMouseDown, .otherMouseDown, .otherMouseUp, .otherMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center)!
            _ = keys.handle(type, event)
        }
        drainCallbacks()
        XCTAssertEqual(transitions, ["down", "up"])
    }
    func testSessionSamplingKeepsLockedAndSwitchedUsersInactive() {
        var session: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        XCTAssertEqual(NativePermissions.sessionIsActive(session), true)
        session["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(NativePermissions.sessionIsActive(session), false)
        session["CGSSessionScreenIsLocked"] = false
        session["kCGSSessionOnConsoleKey"] = false
        XCTAssertEqual(NativePermissions.sessionIsActive(session), false)
        XCTAssertNil(NativePermissions.sessionIsActive([:]))
    }
}
