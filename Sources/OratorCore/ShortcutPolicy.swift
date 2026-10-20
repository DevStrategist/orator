import Foundation

public enum ShortcutEventKind {
    case down, up, flags
}

public struct ShortcutEdges {
    public var starts: Bool
    public var ends: Bool
    public var suppressFn: Bool
}

public enum ShortcutPolicy {
    public static func edges(binding: Hotkey, kind: ShortcutEventKind, keyCode: Int,
                             modifiers: UInt64) -> ShortcutEdges {
        let flags = modifiers & Hotkey.mask
        let required = binding.modifiers & Hotkey.mask
        if binding.isCapsLock {
            // Press and release come from HID; the tap only hides Caps Lock toggles from apps.
            return ShortcutEdges(starts: false, ends: false, suppressFn: false)
        }
        if binding.isFnOnly {
            // Other keys may carry/omit the Fn bit: they are not physical Fn releases.
            guard kind == .flags, keyCode == 63 else {
                return ShortcutEdges(starts: false, ends: false, suppressFn: false)
            }
            let down = flags & UInt64(1 << 23) != 0
            return ShortcutEdges(starts: down, ends: !down, suppressFn: true)
        }
        let matches = flags == required
        if binding.keyCode == -1 {
            return ShortcutEdges(starts: kind == .flags && matches,
                                 ends: kind == .flags && flags & required != required, suppressFn: false)
        }
        return ShortcutEdges(starts: kind == .down && keyCode == binding.keyCode && matches,
                             ends: (kind == .up && keyCode == binding.keyCode) ||
                                   (kind == .flags && flags & required != required), suppressFn: false)
    }
}

public enum TapMode: String {
    case active, listenOnly, unavailable
}

public struct KeyboardDevice: Equatable {
    public var vendorID: Int
    public var product: String
    public var builtIn: Bool
    public init(vendorID: Int, product: String, builtIn: Bool) {
        self.vendorID = vendorID; self.product = product; self.builtIn = builtIn
    }
}

public enum FnKeyPolicy {
    static let appleVendors = [0x05AC, 0x004C]
    // Third-party keyboards resolve Fn in firmware, so macOS never receives keycode 63 from them.
    public static func available(_ keyboards: [KeyboardDevice]) -> Bool {
        guard !keyboards.isEmpty else { return true }
        return keyboards.contains { keyboard in
            keyboard.builtIn || appleVendors.contains(keyboard.vendorID) ||
                keyboard.product.hasPrefix("Apple Internal Keyboard") || keyboard.product.hasPrefix("Magic Keyboard")
        }
    }
}
