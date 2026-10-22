import XCTest
@testable import OratorCore

final class GestureTests: XCTestCase {
    func testHoldThenReleaseStops() {
        var gesture = PushToTalkGesture()
        XCTAssertEqual(gesture.press(now: 0), .start)
        XCTAssertEqual(gesture.release(now: 2), .stop)
        XCTAssertFalse(gesture.active)
    }
    func testQuickTapIsDiscardedAfterDebounce() {
        var gesture = PushToTalkGesture()
        XCTAssertEqual(gesture.press(now: 0), .start)
        XCTAssertEqual(gesture.release(now: 0.2), .none)
        XCTAssertTrue(gesture.awaitingSecondPress)
        XCTAssertEqual(gesture.expire(now: 0.4), .none)
        XCTAssertEqual(gesture.expire(now: 0.7), .discard)
        XCTAssertFalse(gesture.active)
    }
    func testDoubleTapLocksHandsFreeAndNextPressStops() {
        var gesture = PushToTalkGesture()
        XCTAssertEqual(gesture.press(now: 0), .start)
        XCTAssertEqual(gesture.release(now: 0.15), .none)
        XCTAssertEqual(gesture.press(now: 0.35), .lock)
        XCTAssertTrue(gesture.locked)
        XCTAssertEqual(gesture.expire(now: 1), .none)
        XCTAssertEqual(gesture.release(now: 0.5), .none)
        XCTAssertEqual(gesture.release(now: 30), .none)
        XCTAssertEqual(gesture.press(now: 40), .stop)
        XCTAssertFalse(gesture.active)
    }
    func testLateSecondPressAfterDiscardStartsFresh() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0); _ = gesture.release(now: 0.1)
        XCTAssertEqual(gesture.expire(now: 0.6), .discard)
        XCTAssertEqual(gesture.press(now: 2), .start)
    }
    func testRepeatPressWhileHeldDoesNothing() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        XCTAssertEqual(gesture.press(now: 1.5), .none)
        XCTAssertEqual(gesture.release(now: 3), .stop)
    }
    func testDuplicateReleaseIsIgnored() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        XCTAssertEqual(gesture.release(now: 1), .stop)
        XCTAssertEqual(gesture.release(now: 1.1), .none)
    }
    func testDoubleTapWindowStartsAtFirstPress() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        _ = gesture.release(now: 0.4)
        XCTAssertEqual(gesture.press(now: 0.6), .none)
        XCTAssertFalse(gesture.locked)
        XCTAssertEqual(gesture.expire(now: 0.9), .discard)
    }
    func testPressAtDoubleTapBoundaryDoesNotLock() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        _ = gesture.release(now: 0.1)
        XCTAssertEqual(gesture.press(now: 0.5), .none)
        XCTAssertFalse(gesture.locked)
    }
    func testQuickTriplePressDiscardsInsteadOfTranscribing() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        _ = gesture.release(now: 0.1)
        XCTAssertEqual(gesture.press(now: 0.2), .lock)
        _ = gesture.release(now: 0.25)
        XCTAssertEqual(gesture.press(now: 0.3), .discard)
        XCTAssertFalse(gesture.active)
    }
    func testDuplicatePressWithoutReleaseDoesNotLock() {
        var gesture = PushToTalkGesture()
        _ = gesture.press(now: 0)
        XCTAssertEqual(gesture.press(now: 0.2), .none)
        XCTAssertFalse(gesture.locked)
        XCTAssertEqual(gesture.release(now: 1), .stop)
    }
}
