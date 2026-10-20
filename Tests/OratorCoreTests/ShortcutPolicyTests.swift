import XCTest
@testable import OratorCore

final class ShortcutPolicyTests: XCTestCase {
    private let fn = Hotkey(keyCode: -1, modifiers: 1 << 23, label: "Fn")
    func testPhysicalFnPressAndRelease() {
        let down = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: 63, modifiers: 1 << 23)
        XCTAssertTrue(down.starts)
        XCTAssertFalse(down.ends)
        XCTAssertTrue(down.suppressFn)
        let up = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: 63, modifiers: 0)
        XCTAssertFalse(up.starts)
        XCTAssertTrue(up.ends)
        XCTAssertTrue(up.suppressFn)
    }
    func testUnrelatedModifierChangesDoNotReleaseFn() {
        for code in [54, 55, 56, 59] {
            let edge = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: code,
                                            modifiers: (1 << 23) | (1 << 17))
            XCTAssertFalse(edge.starts)
            XCTAssertFalse(edge.ends)
            XCTAssertFalse(edge.suppressFn)
        }
    }
    func testOrdinaryKeysDoNotBecomeFnReleaseEvenIfFlagsOmitFn() {
        for kind: ShortcutEventKind in [.down, .up] {
            let edge = ShortcutPolicy.edges(binding: fn, kind: kind, keyCode: 0, modifiers: 0)
            XCTAssertFalse(edge.starts)
            XCTAssertFalse(edge.ends)
        }
    }
    func testExtraSystemFlagsDoNotBlockFn() {
        let edge = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: 63,
                                        modifiers: (1 << 23) | (1 << 21) | 256)
        XCTAssertTrue(edge.starts)
    }
    func testDuplicateFnEventsDoNotProduceDuplicateStarts() {
        var latch = KeyLatch()
        let edge = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: 63, modifiers: 1 << 23)
        XCTAssertEqual(latch.update(down: edge.starts, matches: true), true)
        XCTAssertNil(latch.update(down: edge.starts, matches: true))
    }
    func testRegularChordStillReleasesWhenRequiredModifierLifts() {
        let binding = Hotkey()
        XCTAssertTrue(ShortcutPolicy.edges(binding: binding, kind: .down, keyCode: 49,
                                           modifiers: binding.modifiers).starts)
        XCTAssertTrue(ShortcutPolicy.edges(binding: binding, kind: .flags, keyCode: 56,
                                           modifiers: 1 << 18).ends)
        XCTAssertFalse(ShortcutPolicy.edges(binding: binding, kind: .flags, keyCode: 58,
                                            modifiers: binding.modifiers | (1 << 19)).ends)
    }
    func testFnOnlyBindingIsRecognized() {
        XCTAssertTrue(fn.isFnOnly)
        XCTAssertFalse(Hotkey().isFnOnly)
        XCTAssertFalse(Hotkey(keyCode: 49, modifiers: 1 << 23, label: "Fn Space").isFnOnly)
    }
    func testBuiltInKeyboardWithoutVendorIDHasFnKey() {
        // MacBook internal keyboards report vendor 0 over the FIFO transport.
        XCTAssertTrue(FnKeyPolicy.available([KeyboardDevice(vendorID: 0, product: "Apple Internal Keyboard", builtIn: true)]))
    }
    func testAppleExternalKeyboardHasFnKey() {
        XCTAssertTrue(FnKeyPolicy.available([KeyboardDevice(vendorID: 0x004C, product: "Keyboard", builtIn: false)]))
        XCTAssertTrue(FnKeyPolicy.available([KeyboardDevice(vendorID: 0, product: "Magic Keyboard with Touch ID", builtIn: false)]))
    }
    func testOnlyThirdPartyKeyboardsHaveNoFnKey() {
        let keychron = KeyboardDevice(vendorID: 0x3434, product: "Keychron K2", builtIn: false)
        XCTAssertFalse(FnKeyPolicy.available([keychron]))
        XCTAssertTrue(FnKeyPolicy.available([keychron, KeyboardDevice(vendorID: 0x05AC, product: "", builtIn: false)]))
    }
    func testUnknownKeyboardInventoryDoesNotWarn() {
        XCTAssertTrue(FnKeyPolicy.available([]))
    }
}
