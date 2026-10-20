import AppKit
import ApplicationServices
import Carbon
import OratorCore
import IOKit.hid

final class Hotkeys {
    private let lock = NSLock()
    private var binding = Hotkey()
    private var latch = KeyLatch()
    private var swallowUp = false
    private var active = false
    private var paused = false
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var thread: Thread?
    private var disabled: [TimeInterval] = []
    private var wakeAt = 0.0
    private var lastPressedAt = 0.0
    private var fnEvents = 0
    private var diagnosticFnEvents = 0
    private var downs = 0
    private var ups = 0
    private var lastFnAt = 0.0
    private var events = 0
    private var recoveredReleases = 0
    private var phantomsSuppressed = 0
    private var previousFlags: UInt64 = 0
    private var flagChangedAt: [UInt64: TimeInterval] = [:]
    private var capsManager: IOHIDManager?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChord: (() -> Void)?
    var onSecureBlocked: (() -> Void)?
    var onStatus: ((Bool, String) -> Void)?
    private(set) var available = false
    private(set) var mode: TapMode = .unavailable

    func configure(_ binding: Hotkey, active: Bool, paused: Bool) {
        lock.lock()
        self.binding = binding; self.active = active; self.paused = paused
        if paused { latch.reset() }
        lock.unlock()
    }
    func didWake() {
        lock.lock(); wakeAt = ProcessInfo.processInfo.systemUptime; latch.reset(); lock.unlock()
    }
    func start(_ requested: TapMode) {
        guard thread == nil, requested != .unavailable else { return }
        let worker = Thread { [weak self] in
            guard let self else { return }
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
                       (1 << CGEventType.flagsChanged.rawValue)
            func create(_ options: CGEventTapOptions) -> CFMachPort? {
                CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: options, eventsOfInterest: CGEventMask(mask),
                                  callback: { _, type, event, pointer in
                    guard let pointer else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<Hotkeys>.fromOpaque(pointer).takeUnretainedValue().handle(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            }
            // When an active tap is refused (stale or missing Accessibility grant), a listen-only tap
            // still delivers the shortcut through Input Monitoring.
            var mode = requested
            var created = mode == .active ? create(.defaultTap) : nil
            if created == nil && CGPreflightListenEventAccess() {
                mode = .listenOnly; created = create(.listenOnly)
            }
            guard let created else {
                DispatchQueue.main.async {
                    self.thread = nil
                    self.report(false, "Keyboard access unavailable; check Accessibility and Input Monitoring")
                }
                return
            }
            self.lock.lock(); self.tap = created; self.loop = CFRunLoopGetCurrent(); self.lock.unlock()
            self.startCapsLockMonitor()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            DispatchQueue.main.async {
                self.mode = mode
                self.report(true, mode == .active ? "Global shortcut ready" :
                    "Global shortcut ready in listen-only mode; other apps also receive the key")
            }
            CFRunLoopRun()
            CFMachPortInvalidate(created)
            if let manager = self.capsManager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                self.capsManager = nil
            }
            self.lock.lock(); self.tap = nil; self.loop = nil; self.lock.unlock()
            DispatchQueue.main.async {
                self.thread = nil; self.mode = .unavailable; self.report(false, "Global shortcut stopped")
            }
        }
        thread = worker; worker.name = "Orator keyboard"; worker.qualityOfService = .userInteractive
        worker.start()
    }
    private func report(_ ready: Bool, _ message: String) {
        available = ready; onStatus?(ready, message)
    }
    func stop() {
        lock.lock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
        latch.reset()
        lock.unlock()
        available = false
    }
    func reconcile() {
        lock.lock()
        defer { lock.unlock() }
        if let tap {
            if !CFMachPortIsValid(tap) {
                if let loop { CFRunLoopStop(loop) }
                return
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        // HID state is the physical keyboard; the session state omits keys this tap swallows.
        guard latch.pressed, !binding.isCapsLock, ProcessInfo.processInfo.systemUptime - lastPressedAt > 2 else { return }
        if binding.keyCode >= 0 {
            guard !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(binding.keyCode)) else { return }
        } else {
            let physicalFlags = CGEventSource.flagsState(.hidSystemState).rawValue & Hotkey.mask
            guard physicalFlags & binding.modifiers != binding.modifiers else { return }
        }
        latch.reset(); recoveredReleases += 1
        DispatchQueue.main.async { self.onUp?() }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !active { latch.reset() }
            if type == .tapDisabledByTimeout && now - wakeAt > 30 {
                disabled = disabled.filter { now - $0 < 60 }; disabled.append(now)
            }
            if disabled.count >= 5 {
                disabled = []
                if let loop { CFRunLoopStop(loop) }
                DispatchQueue.main.async {
                    self.report(false, "Keyboard tap repeatedly disabled; restarting")
                    if self.active { self.onCancel?() }
                }
            } else if let tap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        events += 1
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            let flags = event.flags.rawValue & Hotkey.mask
            for bit in [17, 18, 19, 20, 23].map({ UInt64(1) << $0 }) where (flags ^ previousFlags) & bit != 0 {
                flagChangedAt[bit] = now
            }
            previousFlags = flags
            // Caps Lock toggles are hidden from apps while it is the dictation key.
            if code == Hotkey.capsLockKey && binding.isCapsLock && !paused { return nil }
        }
        if type == .flagsChanged && code == 63 {
            fnEvents += 1; lastFnAt = now
            if event.getIntegerValueField(.eventSourceUserData) == 0x4C464454 { diagnosticFnEvents += 1 }
        }
        let secure = IsSecureEventInputEnabled()
        guard !paused, !secure, event.getIntegerValueField(.eventSourceUserData) != 0x4C464C57 else {
            // Modifier events still arrive under Secure Keyboard Entry; explain why nothing starts.
            if secure && !paused && type != .keyUp && ShortcutPolicy.edges(binding: binding,
                kind: type == .flagsChanged ? .flags : .down, keyCode: code, modifiers: event.flags.rawValue).starts {
                DispatchQueue.main.async { self.onSecureBlocked?() }
            }
            return Unmanaged.passUnretained(event)
        }
        if code == 53 && active {
            if type == .keyDown { DispatchQueue.main.async { self.onCancel?() } }
            return nil
        }
        if type == .keyDown && latch.pressed && code != binding.keyCode && now - lastPressedAt < 1 &&
            event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            // Another key joined the shortcut while starting: the user meant a system chord, not dictation.
            DispatchQueue.main.async { self.onChord?() }
        }
        let kind: ShortcutEventKind = type == .flagsChanged ? .flags : (type == .keyDown ? .down : .up)
        let edges = ShortcutPolicy.edges(binding: binding, kind: kind, keyCode: code,
                                          modifiers: event.flags.rawValue)
        let isModifier = binding.keyCode == -1
        let ownedFn = edges.suppressFn && latch.pressed
        if edges.starts && !latch.pressed && !binding.isFnOnly && isPhantom(now) {
            phantomsSuppressed += 1
            return Unmanaged.passUnretained(event)
        }
        if edges.starts, let transition = latch.update(down: true, matches: true,
                          isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0), transition {
            lastPressedAt = now; swallowUp = !isModifier
            downs += 1
            DispatchQueue.main.async { self.onDown?() }
            return edges.suppressFn || !isModifier ? nil : Unmanaged.passUnretained(event)
        }
        if edges.ends, let transition = latch.update(down: false, matches: false), !transition {
            ups += 1
            DispatchQueue.main.async { self.onUp?() }
        }
        if edges.suppressFn && (ownedFn || latch.pressed) { return nil }
        if code == binding.keyCode && type == .keyUp && swallowUp { swallowUp = false; return nil }
        if code == binding.keyCode && type == .keyDown && latch.pressed { return nil }
        return Unmanaged.passUnretained(event)
    }
    func diagnostics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let enabled = tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
        return ["events": events, "recoveredReleases": recoveredReleases, "phantomsSuppressed": phantomsSuppressed, "fnEvents": fnEvents, "diagnosticFnEvents": diagnosticFnEvents,
                "tapMode": mode.rawValue,
                "presses": downs, "releases": ups, "lastFnAt": lastFnAt,
                "paused": paused, "tapEnabled": enabled, "held": latch.pressed]
    }
    /// A modifier whose last change is older than 2.5 s may be a missed key-up; trust only the hardware.
    private func isPhantom(_ now: TimeInterval) -> Bool {
        let required = binding.modifiers & Hotkey.mask
        let stale = [17, 18, 19, 20, 23].map { UInt64(1) << $0 }.contains { bit in
            required & bit != 0 && now - (flagChangedAt[bit] ?? 0) > 2.5
        }
        guard stale else { return false }
        return CGEventSource.flagsState(.hidSystemState).rawValue & required != required
    }
    /// Caps Lock reports only toggles to event taps; HID gives real press and release.
    private func startCapsLockMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
                                                    kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().capsLock(down: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        capsManager = manager
    }
    private func capsLock(down: Bool) {
        lock.lock()
        guard binding.isCapsLock, !paused else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = latch.update(down: down, matches: true) {
            if transition { lastPressedAt = now; downs += 1; DispatchQueue.main.async { self.onDown?() } }
            else { ups += 1; DispatchQueue.main.async { self.onUp?() } }
        }
        lock.unlock()
        // macOS toggles the lock on press or release depending on timing; clear it after both.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05) { Self.clearCapsLock() }
    }
    static func clearCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
    }
    static func keyboards() -> [KeyboardDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { device in
            func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            return KeyboardDevice(vendorID: property(kIOHIDVendorIDKey) as? Int ?? 0,
                                  product: property(kIOHIDProductKey) as? String ?? "",
                                  builtIn: property(kIOHIDBuiltInKey) as? Bool ?? false)
        }
    }
}
