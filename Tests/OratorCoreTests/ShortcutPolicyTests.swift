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
    func testReleasingUnrelatedModifierCannotStartDictation() {
        let control = Hotkey(keyCode: -1, modifiers: 1 << 18, label: "Control")
        for code in [54, 55, 56, 57, 58, 60, 61, 63] {
            XCTAssertFalse(ShortcutPolicy.edges(binding: control, kind: .flags, keyCode: code,
                                                modifiers: 1 << 18).starts)
        }
        XCTAssertTrue(ShortcutPolicy.edges(binding: control, kind: .flags, keyCode: 59,
                                           modifiers: 1 << 18).starts)
        XCTAssertTrue(ShortcutPolicy.edges(binding: control, kind: .flags, keyCode: 62,
                                           modifiers: 1 << 18).starts)
    }
    func testFnWithOtherModifiersDoesNotStartFnOnlyShortcut() {
        let edge = ShortcutPolicy.edges(binding: fn, kind: .flags, keyCode: 63,
                                         modifiers: (1 << 23) | (1 << 20))
        XCTAssertFalse(edge.starts)
        XCTAssertFalse(edge.ends)
    }
    func testMouseShortcutsPersistAndMatchPressAndRelease() throws {
        for button in [2, 3, 4, 31] {
            var settings = Settings()
            settings.hotkey = Hotkey(keyCode: 128 + button, modifiers: 0, label: "Mouse \(button + 1)")
            settings.validate()
            XCTAssertEqual(settings.hotkey.keyCode, 128 + button)
            let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.hotkey, settings.hotkey)
            XCTAssertTrue(ShortcutPolicy.edges(binding: settings.hotkey, kind: .down,
                                               keyCode: 128 + button, modifiers: 0).starts)
            XCTAssertTrue(ShortcutPolicy.edges(binding: settings.hotkey, kind: .up,
                                               keyCode: 128 + button, modifiers: 0).ends)
        }
        for keyCode in [128, 129, 160, 200, Int.min, Int.max] {
            XCTAssertFalse(Hotkey(keyCode: keyCode, modifiers: 0).isValid)
        }
    }
}
