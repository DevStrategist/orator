import AppKit
import Foundation

/// Pauses Spotify or Music while dictating and resumes only what it paused. Uses each player's
/// scripting interface, so macOS asks once for permission to control that app.
final class MediaPause {
    static let players = ["com.spotify.client", "com.apple.Music"]
    private let queue = DispatchQueue(label: "orator.media-pause")
    private var paused: [String] = []

    func pause() {
        queue.async {
            guard self.paused.isEmpty else { return }
            for player in Self.players where Self.running(player) {
                let state = Self.run("tell application id \"\(player)\"\nif player state is playing then\npause\nreturn \"paused\"\nend if\nend tell")
                if state == "paused" { self.paused.append(player) }
            }
        }
    }
    func resume() {
        queue.async {
            for player in self.paused where Self.running(player) {
                // A user who pressed play or stop meanwhile keeps their choice.
                _ = Self.run("tell application id \"\(player)\" to if player state is paused then play")
            }
            self.paused = []
        }
    }
    private static func running(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
    /// osascript keeps a slow or hung player from blocking Orator; it is killed after 2 seconds.
    private static func run(_ script: String) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
