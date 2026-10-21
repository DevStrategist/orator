import AppKit

/// Orator's start and stop sounds, loaded once so the first cue plays without delay.
/// Rendered by scripts/make_sounds.py; falls back to system sounds in builds without them.
enum Cues {
    private static let start = load("start", fallback: "Tink")
    private static let stop = load("stop", fallback: "Pop")

    static func preload() { _ = (start, stop) }
    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        // Restart rather than skip if the previous cue is still sounding.
        sound.stop()
        sound.play()
    }
    private static func load(_ name: String, fallback: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: false) { return sound }
        return NSSound(named: fallback)
    }
}
