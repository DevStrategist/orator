import Foundation

public enum Phase: String, Codable {
    case idle, starting, recording, stopping, transcribing, inserting, failed
}

public struct RestartBudget {
    private var failures: [TimeInterval] = []
    public init() {}
    public mutating func recordFailure(now: TimeInterval) { failures.append(now) }
    public mutating func canStart(now: TimeInterval) -> Bool {
        failures = failures.filter { now >= $0 && now - $0 < 60 }
        return failures.count < 4
    }
}

public struct SessionMachine {
    public private(set) var phase: Phase = .idle
    public private(set) var id: String?
    public init() {}
    @discardableResult public mutating func begin(_ id: String) -> Bool {
        guard phase == .idle, UUID(uuidString: id) != nil else { return false }
        self.id = id
        phase = .starting
        return true
    }
    @discardableResult public mutating func advance(_ id: String, to next: Phase) -> Bool {
        guard self.id == id else { return false }
        let allowed: [Phase: Set<Phase>] = [
            .starting: [.recording, .stopping, .failed],
            .recording: [.stopping, .failed],
            .stopping: [.transcribing, .failed],
            .transcribing: [.inserting, .failed],
            .inserting: [.idle, .failed],
            .failed: [.idle, .transcribing],
            .idle: []
        ]
        guard allowed[phase, default: []].contains(next) else { return false }
        phase = next
        if next == .idle { self.id = nil }
        return true
    }
    public mutating func cancel() { id = nil; phase = .idle }
}

public struct Hotkey: Codable, Equatable {
    public var keyCode: Int
    public var modifiers: UInt64
    public var label: String
    public init(keyCode: Int = 49, modifiers: UInt64 = (1 << 18) | (1 << 17),
                label: String = "⌃⇧Space") {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public static let mask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
    public var isFnOnly: Bool { keyCode == -1 && modifiers & Self.mask == UInt64(1 << 23) }
    public static let capsLockKey = 57
    public static let capsLock = Hotkey(keyCode: capsLockKey, modifiers: 0, label: "⇪ Caps Lock")
    /// Caps Lock only reports toggles to event taps, so it is read from HID as a single-key shortcut.
    public var isCapsLock: Bool { keyCode == Self.capsLockKey }
    public var isValid: Bool {
        if isCapsLock { return modifiers & Self.mask == 0 }
        guard (-1...127).contains(keyCode), modifiers & Self.mask != 0 else { return false }
        let flags = modifiers & Self.mask
        let command = UInt64(1 << 20)
        if keyCode == 49 && flags == command { return false }
        if [51, 117].contains(keyCode) && flags == command { return false }
        if keyCode == 3 && flags == command | UInt64(1 << 18) { return false }
        return true
    }
}

public struct KeyLatch {
    public private(set) var pressed = false
    public init() {}
    public mutating func update(down: Bool, matches: Bool, isRepeat: Bool = false) -> Bool? {
        if down && matches && !isRepeat && !pressed { pressed = true; return true }
        if !down && pressed { pressed = false; return false }
        return nil
    }
    public mutating func reset() { pressed = false }
}

public struct Replacement: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct Settings: Codable, Equatable {
    public var hotkey = Hotkey()
    public var toggleMode = false
    public var microphoneUID = ""
    public var modelPath = ""
    public var maxSeconds = 300
    public var sounds = true
    public var autoInsert = true
    public var preserveClipboard = true
    public var neverStore = false
    public var replacements: [Replacement] = []
    public var smartFormatting = true
    public var pasteWithoutCursor = true
    public var muteWhileDictating = false
    public var pauseMediaWhileDictating = false
    public init() {}
    // Settings saved by older builds lack newer keys; keep their values instead of resetting everything.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = Settings()
        hotkey = value(.hotkey, defaults.hotkey)
        toggleMode = value(.toggleMode, defaults.toggleMode)
        microphoneUID = value(.microphoneUID, defaults.microphoneUID)
        modelPath = value(.modelPath, defaults.modelPath)
        maxSeconds = value(.maxSeconds, defaults.maxSeconds)
        sounds = value(.sounds, defaults.sounds)
        autoInsert = value(.autoInsert, defaults.autoInsert)
        preserveClipboard = value(.preserveClipboard, defaults.preserveClipboard)
        neverStore = value(.neverStore, defaults.neverStore)
        replacements = value(.replacements, defaults.replacements)
        smartFormatting = value(.smartFormatting, defaults.smartFormatting)
        pasteWithoutCursor = value(.pasteWithoutCursor, defaults.pasteWithoutCursor)
        muteWhileDictating = value(.muteWhileDictating, defaults.muteWhileDictating)
        pauseMediaWhileDictating = value(.pauseMediaWhileDictating, defaults.pauseMediaWhileDictating)
    }
    public mutating func validate() {
        if !hotkey.isValid { hotkey = Hotkey() }
        // Pausing and muting are alternatives; muting a paused player would hide the resume.
        if pauseMediaWhileDictating { muteWhileDictating = false }
        maxSeconds = min(1200, max(10, maxSeconds))
        replacements = Array(replacements.filter { !$0.from.isEmpty }.prefix(200))
    }
    public func transform(_ text: String) -> String {
        replacements.reduce(text) { value, rule in
            guard !rule.from.isEmpty else { return value }
            return value.replacingOccurrences(of: rule.from, with: rule.to)
        }
    }
}

public struct Recovery: Codable {
    public var id: String
    public var created: Date
    public var sampleRate: Int
    public var samples: Int
    public var failureReason: String?
    public init(id: String) {
        self.id = id; created = Date(); sampleRate = 16000; samples = 0
    }
}

public enum OratorPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orator", isDirectory: true)
    }
    /// Builds released before the rename kept their data here.
    public static var legacySupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Local Flow", isDirectory: true)
    }
    /// Moves an earlier install's model, runtime and settings into place once, keeping everything local.
    public static func migrateLegacySupport(from legacy: URL = legacySupport, to destination: URL = support) {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path), !files.fileExists(atPath: destination.path) else { return }
        try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: legacy, to: destination)
    }
    public static var recordings: URL { support.appendingPathComponent("Recordings", isDirectory: true) }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    /// Parakeet TDT 0.6B v3 with an 8-bit encoder (755 MB).
    public static var model: URL { support.appendingPathComponent("models/parakeet-tdt-0.6b-v3-int8", isDirectory: true) }
    /// The full-precision 2.5 GB model used by earlier builds; removed once the new model is running.
    public static var legacyModel: URL { support.appendingPathComponent("model", isDirectory: true) }
    public static func prepare() throws {
        migrateLegacySupport()
        for path in [support, recordings] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
    }
    public static func pcm(_ id: String) -> URL { recordings.appendingPathComponent(id + ".pcm") }
    public static func manifest(_ id: String) -> URL { recordings.appendingPathComponent(id + ".json") }
    public static func remove(_ id: String, directory: URL = recordings) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".pcm"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
    }
    public static func recoveries(now: Date = Date(), directory: URL = recordings) -> [Recovery] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                            includingPropertiesForKeys: nil)) ?? []
        var result: [Recovery] = []
        for path in entries where path.pathExtension == "json" {
            guard let data = try? Data(contentsOf: path),
                  let recovery = try? JSONDecoder().decode(Recovery.self, from: data),
                  UUID(uuidString: recovery.id) != nil else {
                let id = path.deletingPathExtension().lastPathComponent
                if let modified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) >= 86400 { remove(id, directory: directory) }
                continue
            }
            if now.timeIntervalSince(recovery.created) >= 86400 {
                remove(recovery.id, directory: directory)
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent(recovery.id + ".pcm").path) {
                result.append(recovery)
            }
        }
        return result.sorted { $0.created > $1.created }
    }
}

public struct JSONLineBuffer {
    private var buffer = Data()
    public var limit: Int
    public init(limit: Int = 1_048_576) { self.limit = limit }
    public mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= limit else { throw ProtocolError.oversized }
        var results: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ProtocolError.invalid
            }
            results.append(object)
        }
        return results
    }
    public enum ProtocolError: Error { case oversized, invalid }
}

public enum PastePolicy {
    public static func safePayload(_ text: String, terminal: Bool) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 27 { return false }
            if terminal && (CharacterSet.controlCharacters.contains(scalar) ||
                             scalar.value == 0x2028 || scalar.value == 0x2029) { return false }
        }
        return true
    }
    public static func canRestore(ownedCount: Int, currentCount: Int, ownedID: String, currentID: String?) -> Bool {
        ownedCount == currentCount && ownedID == currentID
    }
    public static func expectedEdit(before: String, range: NSRange, inserted: String) -> String? {
        let text = before as NSString
        guard range.location != NSNotFound, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.replacingCharacters(in: range, with: inserted)
    }
}
