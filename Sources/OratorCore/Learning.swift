import Foundation

/// Finds words a user corrected right after dictation, so they can become vocabulary replacements.
public enum EditLearning {
    /// The dictated region as it reads now, if the text around it is untouched.
    public static func editedRegion(prefix: String, suffix: String, current: String) -> String? {
        guard current.hasPrefix(prefix), current.hasSuffix(suffix),
              current.utf16.count >= prefix.utf16.count + suffix.utf16.count else { return nil }
        let text = current as NSString
        let start = (prefix as NSString).length
        return text.substring(with: NSRange(location: start, length: text.length - start - (suffix as NSString).length))
    }

    /// Word-for-word corrections; a different word count means a rewrite, not a correction.
    public static func corrections(inserted: String, edited: String, limit: Int = 3) -> [Replacement] {
        let before = words(inserted), after = words(edited)
        guard before.count == after.count, before != after else { return [] }
        var result: [Replacement] = []
        for (heard, fixed) in zip(before, after) where heard != fixed {
            guard heard.count >= 2, fixed.count >= 2, fixed.contains(where: \.isLetter),
                  distance(heard.lowercased(), fixed.lowercased()) <= max(2, max(heard.count, fixed.count) / 2),
                  !result.contains(where: { $0.from == heard }) else { continue }
            result.append(Replacement(from: heard, to: fixed))
            if result.count == limit { break }
        }
        return result
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-")))
        }.filter { !$0.isEmpty }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}

/// Post-dictation microphone quality from 0.25 s RMS windows, measured locally.
public enum AudioQuality {
    public struct Report: Equatable {
        public var speechDB: Double
        public var snrDB: Double
        public var poor: Bool
    }
    public static func assess(_ windows: [Double]) -> Report? {
        guard windows.count >= 8 else { return nil }
        let sorted = windows.sorted()
        func db(_ value: Double) -> Double { 20 * log10(max(value, 1e-6)) }
        let noise = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let speech = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let speechDB = db(speech), snr = speechDB - db(noise)
        return Report(speechDB: speechDB, snrDB: snr, poor: speechDB < -50 || snr < 6)
    }
}

public enum RemoteViewers {
    /// Viewers that forward the local clipboard to a remote machine only when they regain focus.
    public static let bundleIDs: Set<String> = [
        "com.realvnc.vncviewer", "com.tigervnc.vncviewer", "org.tigervnc.vncviewer",
        "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.p5sys.jump.mac.viewer",
        "com.p5sys.jump.mac.viewer.web"
    ]
    public static func contains(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }
}
