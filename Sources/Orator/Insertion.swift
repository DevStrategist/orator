import AppKit
import ApplicationServices
import Carbon
import OratorCore

struct TargetSnapshot {
    let pid: pid_t
    let element: AXUIElement
    let role: String
    let subrole: String
    let range: NSRange?
    let value: String?
    var bundleID: String = ""

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func selection(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static var exposedApps = Set<pid_t>()
    static func capture() -> TargetSnapshot? {
        guard NativePermissions.accessibilityTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        if exposedApps.insert(app.processIdentifier).inserted {
            // Electron and Chromium build their accessibility tree only when asked; other apps ignore this.
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        // Without a focused element (common in web views), the focused window still identifies the target.
        guard let raw = attribute(application, kAXFocusedUIElementAttribute) ??
                        attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let value = attribute(element, kAXValueAttribute) as? String
        return TargetSnapshot(pid: app.processIdentifier, element: element, role: role,
                              subrole: subrole, range: selection(element),
                              value: value.flatMap { $0.utf16.count <= 100_000 ? $0 : nil },
                              bundleID: app.bundleIdentifier ?? "")
    }
    var isSafe: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) && !isSecure &&
        (Self.attribute(element, kAXEnabledAttribute) as? Bool ?? true)
    }
    var isSecure: Bool {
        subrole.localizedCaseInsensitiveContains("secure") || role.localizedCaseInsensitiveContains("secure")
    }
    func sameFocus(_ other: TargetSnapshot) -> Bool { pid == other.pid && CFEqual(element, other.element) }
    /// Up to 64 UTF-16 units either side of the selection, never splitting a composed character.
    func context(_ range: NSRange) -> (before: String, after: String) {
        guard let value, Self.attribute(element, "AXPlaceholderValue") as? String != value else { return ("", "") }
        let text = value as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return ("", "") }
        let start = max(0, range.location - 64), end = min(text.length, NSMaxRange(range) + 64)
        let before = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: range.location - start))
        let after = text.rangeOfComposedCharacterSequences(for: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        return (text.substring(with: NSIntersectionRange(before, NSRange(location: 0, length: range.location))),
                text.substring(with: NSIntersectionRange(after, NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range)))))
    }
    func matches(_ other: TargetSnapshot) -> Bool {
        pid == other.pid && CFEqual(element, other.element) && range == other.range &&
        (value == nil || other.value == value)
    }
}

private final class ClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    var onRead: (() -> Void)?
    init(_ text: String) { self.text = text }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .string { item.setString(text, forType: .string) }
        DispatchQueue.main.async { [weak self] in self?.onRead?() }
    }
}

final class Insertion {
    /// A verified insertion: the exact text placed between untouched surroundings.
    struct Verified {
        let pid: pid_t
        let element: AXUIElement
        let prefix: String
        let suffix: String
        let text: String
    }
    private static let marker = NSPasteboard.PasteboardType("com.devstrategist.orator.transaction")
    private(set) var lastVerified: Verified?
    private var provider: ClipboardProvider?
    private var pendingCancel: (() -> Void)?
    private var generation = UUID()
    var busy: Bool { provider != nil }

    func cancel() { generation = UUID(); pendingCancel?(); pendingCancel = nil }
    private func pasteKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for key in UInt16(0)...UInt16(127) {
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
                UInt32(cmdKey >> 8), UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead,
                characters.count, &length, &characters)
            if result == noErr && length == 1 && characters[0] == 118 { return CGKeyCode(key) }
        }
        return nil
    }

    func insert(_ transcript: String, target: TargetSnapshot?, preserve: Bool, smart: Bool = false,
                unverified allowUnverified: Bool = false, completion: @escaping (String, Bool) -> Void) {
        guard !busy else { completion("Clipboard delivery is still finishing. Use Copy last.", false); return }
        let currentGeneration = UUID()
        generation = currentGeneration
        lastVerified = nil
        guard !IsSecureEventInputEnabled(), let target, !target.isSecure,
              let current = TargetSnapshot.capture(), !current.isSecure else {
            completion("Target or cursor changed. Transcript saved here; use Copy last.", false); return
        }
        let range = target.isSafe && current.isSafe && target.matches(current) ? current.range : nil
        // Apps that hide their text (web views, canvases, terminals) still get a paste into the same
        // focused element, reported as unverified rather than refused.
        guard range != nil || (allowUnverified && target.sameFocus(current)) else {
            completion(target.sameFocus(current) && current.range == nil ?
                       "This app does not expose a safe insertion point. Use Copy last." :
                       "Target or cursor changed. Transcript saved here; use Copy last.", false); return
        }
        var text = transcript
        if smart, let range {
            let around = current.context(range)
            text = SmartText.adapt(transcript, before: around.before, after: around.after)
        }
        let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                         "dev.warp.warp-stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"]
        guard PastePolicy.safePayload(text, terminal: terminals.contains(current.bundleID.lowercased())) else {
            completion("Control characters or multiline terminal text require explicit Copy and manual paste.", false); return
        }
        let expected = range.flatMap { range in
            current.value.flatMap { PastePolicy.expectedEdit(before: $0, range: range, inserted: text) }
        }
        func recordVerified() {
            guard let range, let expected else { return }
            let full = expected as NSString, length = (text as NSString).length
            lastVerified = Verified(pid: current.pid, element: current.element,
                                    prefix: full.substring(to: range.location),
                                    suffix: full.substring(from: range.location + length), text: text)
        }
        let remote = range == nil && RemoteViewers.contains(current.bundleID)
        var writable: DarwinBoolean = false
        let canAX = range != nil && AXUIElementIsAttributeSettable(current.element, kAXSelectedTextAttribute as CFString,
                                                 &writable) == .success && writable.boolValue
        if canAX {
            let result = AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString,
                                                      text as CFString)
            if result == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard self.generation == currentGeneration else { return }
                    let value = TargetSnapshot.attribute(current.element, kAXValueAttribute) as? String
                    if expected != nil && value == expected { recordVerified() }
                    completion(expected != nil && value == expected ? "Text inserted and verified." :
                               "Insertion accepted by app. Transcript remains available here.", true)
                }
                return
            }
            guard let unchanged = TargetSnapshot.capture(), current.matches(unchanged) else {
                completion("Insertion outcome uncertain. Check the field before pasting again.", false); return
            }
        }
        let board = NSPasteboard.general
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        var preserving = preserve
        if preserve {
            // Snapshot every materializable type; promises or oversized content are not restored, but
            // they no longer block insertion either.
            snapshot: for item in board.pasteboardItems ?? [] {
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { preserving = false; break snapshot }
                    bytes += data.count
                    guard bytes <= 8_388_608 else { preserving = false; break snapshot }
                    values[type] = data
                }
                saved.append(values)
            }
            if !preserving { saved = [] }
        }
        let keptNote = preserve && !preserving ? " Your previous clipboard could not be kept." : ""
        func stillTargeted(_ latest: TargetSnapshot?) -> Bool {
            guard let latest else { return false }
            return range == nil ? current.sameFocus(latest) : current.matches(latest)
        }
        guard stillTargeted(TargetSnapshot.capture()) else {
            completion("Focus changed before paste. Use Copy last.", false); return
        }
        let transaction = UUID().uuidString
        let payload = ClipboardProvider(text)
        let item = NSPasteboardItem()
        item.setDataProvider(payload, forTypes: [.string])
        item.setString(transaction, forType: Self.marker)
        board.clearContents()
        let clearedCount = board.changeCount
        guard board.writeObjects([item]) else {
            if preserving && board.changeCount == clearedCount && (board.pasteboardItems ?? []).isEmpty {
                let previous = saved.map { values -> NSPasteboardItem in
                    let savedItem = NSPasteboardItem()
                    for (type, data) in values { savedItem.setData(data, forType: type) }
                    return savedItem
                }
                if !previous.isEmpty { board.writeObjects(previous) }
            }
            completion("Clipboard write failed. Use Copy last.", false); return
        }
        let count = board.changeCount
        provider = payload
        var pastePosted = false
        var readAt: TimeInterval?
        var readBeforePaste = false
        var postedAt = 0.0
        payload.onRead = {
            guard readAt == nil else { return }
            readAt = ProcessInfo.processInfo.systemUptime
            // A clipboard manager reads eagerly; the provider then never sees the target's read.
            if !pastePosted { readBeforePaste = true }
        }
        let began = ProcessInfo.processInfo.systemUptime
        var timer: Timer?
        var finished = false
        func finish(_ message: String, restore: Bool, delivered: Bool = false) {
            guard !finished else { return }
            finished = true; timer?.invalidate(); timer = nil
            if restore && preserving && PastePolicy.canRestore(ownedCount: count, currentCount: board.changeCount,
                                      ownedID: transaction, currentID: board.string(forType: Self.marker)) {
                let items = saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                board.clearContents()
                if !items.isEmpty { board.writeObjects(items) }
            } else if PastePolicy.canRestore(ownedCount: count, currentCount: board.changeCount,
                                            ownedID: transaction, currentID: board.string(forType: Self.marker)) {
                // Materialize before releasing the provider; keep the transcript for manual recovery.
                item.setString(text, forType: .string)
            }
            self.provider = nil; self.pendingCancel = nil
            completion(message + keptNote, delivered)
        }
        pendingCancel = {
            finish(pastePosted ? "Paste cancelled. Check the field before retrying." :
                   "Paste cancelled before dispatch.", restore: !pastePosted)
        }
        guard let pasteKey = pasteKeyCode() else {
            finish("Cannot resolve this keyboard layout safely. Use Copy last.", restore: true); return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: false)
        guard let down, let up else { finish("Cannot create paste event. Use Copy last.", restore: true); return }
        // Wait for real shortcut modifiers to be released instead of injecting into a held chord.
        func postWhenReleased(_ attempts: Int) {
            guard !finished else { return }
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue & Hotkey.mask
            guard flags == 0 else {
                if attempts > 30 { finish("Release modifier keys, then use Copy last.", restore: true); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { postWhenReleased(attempts + 1) }
                return
            }
            guard stillTargeted(TargetSnapshot.capture()) else {
                finish("Focus changed before paste. Use Copy last.", restore: true); return
            }
            if remote {
                bounceRemoteViewer(); return
            }
            postPaste()
        }
        func postPaste() {
            pastePosted = true; postedAt = ProcessInfo.processInfo.systemUptime
            for event in [down, up] {
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: 0x4C464C57)
                event.post(tap: .cghidEventTap)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                guard !finished else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if remote {
                    // The remote machine pastes later; keep the transcript on the clipboard for it.
                    if now - postedAt >= 1 { finish("Sent to the remote session. The transcript stays on the clipboard.", restore: false, delivered: true) }
                    return
                }
                if range == nil {
                    if let readAt, !readBeforePaste, now - readAt >= 0.75 {
                        finish("Pasted. This app doesn't report its text, so give it a quick check.", restore: true, delivered: true)
                    } else if readBeforePaste && now - postedAt >= 1 {
                        finish("Pasted. This app doesn't report its text, so give it a quick check.", restore: true, delivered: true)
                    } else if readAt == nil && now - postedAt >= 1.5 {
                        finish("Nothing accepted the paste. The transcript is on the clipboard; click a text box and paste.", restore: false)
                    }
                    return
                }
                let sameTarget = TargetSnapshot.capture().map { $0.pid == current.pid && CFEqual($0.element, current.element) } ?? false
                let value = sameTarget ? TargetSnapshot.attribute(current.element, kAXValueAttribute) as? String : nil
                if let expected, value == expected {
                    recordVerified()
                    finish("Text pasted and verified.", restore: true, delivered: true)
                } else if let readAt, now - readAt >= 0.75 {
                    // The target read the clipboard after the paste; its text just isn't readable back.
                    finish("Pasted. The app didn't report the edit, so give it a quick check.", restore: true, delivered: true)
                } else if now - began >= 5 {
                    finish("Paste unconfirmed. Transcript is available for manual recovery.", restore: false)
                }
            }
        }
        /// Remote viewers sync the clipboard when they regain focus, so hand focus away and back first.
        func bounceRemoteViewer() {
            guard let viewer = NSRunningApplication(processIdentifier: current.pid),
                  let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
                postPaste(); return
            }
            finder.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard !finished else { return }
                viewer.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard !finished else { return }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid else {
                        finish("The remote viewer did not come back to the front. The transcript is on the clipboard.", restore: false)
                        return
                    }
                    postPaste()
                }
            }
        }
        postWhenReleased(0)
    }
}
