import XCTest
import AppKit
import SwiftUI
import OratorCore
@testable import Orator

/// Renders the UI to PNGs for visual review when ORATOR_SNAPSHOT_DIR is set.
final class SnapshotTests: XCTestCase {
    private func render<V: View>(_ view: V, size: NSSize, name: String, to folder: URL) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
    private func readyController() -> Controller {
        let app = Controller(startServices: false)
        app.microphone = true; app.accessibility = true; app.shortcutReady = true
        app.modelReady = true; app.captureReady = true
        app.settings.hotkey = Hotkey(keyCode: -1, modifiers: 1 << 23, label: "Fn")
        app.settings.replacements = [Replacement(from: "orater", to: "Orator"), Replacement(from: "cube control", to: "kubectl")]
        app.lastText = "Let's move the launch review to Thursday and ask Priya to bring the updated onboarding numbers."
        app.message = "Text inserted and verified."
        app.devices = [("built-in", "MacBook Neo Microphone"), ("usb", "Shure MV7")]
        return app
    }
    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["ORATOR_SNAPSHOT_DIR"] else { throw XCTSkip("Set ORATOR_SNAPSHOT_DIR") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = readyController()
        for page in Page.allCases {
            try render(SettingsView(app: app, page: page), size: NSSize(width: 900, height: 640), name: "page-\(page.rawValue)", to: folder)
        }
        let fresh = Controller(startServices: false)
        try render(SettingsView(app: fresh), size: NSSize(width: 900, height: 640), name: "page-Setup", to: folder)

        let hud = readyController()
        hud.phase = .recording; hud.level = 0.05; hud.seconds = 7
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 360, height: 110), name: "hud-listening", to: folder)
        hud.handsFree = true
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 360, height: 110), name: "hud-handsfree", to: folder)
        hud.handsFree = false; hud.silentInput = true
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 560, height: 110), name: "hud-hint", to: folder)
        hud.silentInput = false; hud.phase = .transcribing
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 360, height: 110), name: "hud-transcribing", to: folder)
        hud.phase = .idle; hud.undoAvailable = true; hud.notice = "Dictation cancelled."
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 420, height: 110), name: "hud-undo", to: folder)
        hud.undoAvailable = false
        hud.notice = "The microphone sent only silence. Check that it isn't muted, or pick another input in Settings."
        try render(RecordingHUD(app: hud).padding(30).background(Color(white: 0.85)), size: NSSize(width: 600, height: 130), name: "hud-notice", to: folder)
    }
}
