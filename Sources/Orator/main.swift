import AppKit
import SwiftUI
import OratorCore
import Darwin
import Combine

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var controller: Controller!
    var status: NSStatusItem!
    var window: NSWindow?
    var hud: NSPanel?
    var hudHost: NSHostingView<RecordingHUD>?
    var hudSizing: AnyCancellable?
    var lockFile: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try OratorPaths.prepare() } catch { NSApp.terminate(nil); return }
        lockFile = open(OratorPaths.support.appendingPathComponent("application.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        controller = Controller()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = Self.menuBarMark()
        status.button?.toolTip = "Orator: private dictation"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        controller.onChange = { [weak self] in self?.update() }
        controller.showWindow = { [weak self] in self?.showSettings() }
        controller.relaunchApplication = { [weak self] in self?.relaunch() }
        update()
        if CommandLine.arguments.contains("--verify-fn-capture") {
            controller.requestCaptureDiagnostic()
        } else if CommandLine.arguments.contains("--verify-text-insertion") {
            controller.requestTextInsertionDiagnostic()
        } else {
            // Settings are the control surface, not an onboarding sequence.
            showSettings()
        }
    }
    static func menuBarMark() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "orator-mark", withExtension: "svg"),
              let mark = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Orator")
        }
        mark.size = NSSize(width: 18, height: 18)
        mark.isTemplate = true
        mark.accessibilityDescription = "Orator"
        return mark
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func showSettings() {
        if window == nil {
            let view = NSHostingView(rootView: SettingsView(app: controller))
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            settings.title = "Orator"
            settings.titleVisibility = .hidden; settings.titlebarAppearsTransparent = true
            settings.appearance = NSAppearance(named: .aqua)
            settings.backgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.984, alpha: 1)
            settings.minSize = NSSize(width: 820, height: 580)
            settings.contentView = view; settings.isReleasedWhenClosed = false
            settings.delegate = self; settings.center()
            window = settings
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let monitor = controller.shortcutMonitor { NSEvent.removeMonitor(monitor); controller.shortcutMonitor = nil }
        controller.recordingShortcut = false
    }
    func menuWillOpen(_ menu: NSMenu) {
        controller.menuTarget = TargetSnapshot.capture()
        menu.removeAllItems()
        let state = NSMenuItem(title: controller.message, action: nil, keyEquivalent: "")
        state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        add(menu, controller.busy ? "Stop dictation" : "Start dictation", #selector(toggle))
        if controller.busy { add(menu, "Cancel", #selector(cancel)) }
        add(menu, "Copy last transcript", #selector(copyLast), enabled: !controller.lastText.isEmpty)
        add(menu, "Paste last transcript", #selector(pasteLast), enabled: !controller.busy && !controller.lastText.isEmpty)
        if !controller.recoveries.isEmpty || controller.phase == .failed {
            add(menu, "Recover pending audio…", #selector(recover), enabled: !controller.busy)
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(settings))
        add(menu, "Restart services", #selector(restart), enabled: !controller.busy)
        add(menu, "Quit Orator", #selector(quit))
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; menu.addItem(item)
    }
    func update() {
        guard controller != nil else { return }
        status?.button?.contentTintColor = controller.phase == .recording ? .systemRed : nil
        // The HUD follows the hotkey: visible while held and transcribing, gone once the paste is sent.
        if controller.hudPhase || controller.notice != nil {
            if hud == nil {
                let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.appearance = NSAppearance(named: .aqua)
                let host = NSHostingView(rootView: RecordingHUD(app: controller))
                panel.contentView = host; hudHost = host
                // The SwiftUI capsule draws its own shadow; the panel hugs it so it never blocks clicks around it.
                panel.hasShadow = false; hud = panel
                hudSizing = controller.objectWillChange.sink { [weak self] _ in
                    DispatchQueue.main.async { self?.layoutHUD() }
                }
            }
            layoutHUD()
            // Draw the rounded content before exposing the window's first frame.
            hudHost?.layoutSubtreeIfNeeded()
            hud?.displayIfNeeded()
            hud?.orderFrontRegardless()
        } else {
            hud?.orderOut(nil)
            // Hidden SwiftUI content otherwise animates the previous notice into the next recording.
            hudSizing = nil; hudHost = nil; hud = nil
        }
    }
    func layoutHUD() {
        guard let hud, let host = hudHost, hud.isVisible || controller.hudPhase || controller.notice != nil,
              let screen = NSScreen.main else { return }
        let size = host.fittingSize
        let frame = NSRect(x: (screen.visibleFrame.midX - size.width / 2).rounded(), y: screen.visibleFrame.minY + 6,
                           width: size.width, height: size.height)
        if hud.frame != frame { hud.setFrame(frame, display: true) }
    }
    @objc func toggle() {
        if controller.phase == .recording || controller.phase == .starting { controller.stopRecording() }
        else if !controller.busy { controller.begin(target: controller.menuTarget) }
    }
    @objc func cancel() { controller.cancel() }
    @objc func copyLast() { controller.copyLast() }
    @objc func pasteLast() { controller.pasteLast() }
    @objc func recover() { showSettings() }
    @objc func settings() { showSettings() }
    @objc func restart() { controller.restart() }
    @objc func quit() { NSApp.terminate(nil) }
    func relaunch() {
        guard !controller.busy else { return }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c",
            "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -lt 100 ] || exit 1; /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
            "orator-relaunch", String(getpid()), Bundle.main.bundlePath]
        launcher.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do { try launcher.run(); NSApp.terminate(nil) }
        catch { controller.message = "Could not schedule relaunch. Quit and reopen Orator manually." }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        controller.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if lockFile >= 0 { flock(lockFile, LOCK_UN); close(lockFile) }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
