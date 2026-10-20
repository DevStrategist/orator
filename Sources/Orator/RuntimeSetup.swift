import CryptoKit
import Foundation
import OratorCore

/// First-launch setup: installs the speech engine with the bundled uv and downloads the pinned model into
/// Orator's private folder. Runs again only when the bundled lock file changes or files are missing.
final class RuntimeSetup {
    enum Stage: Equatable {
        case idle, installingEngine, downloadingModel(Double?), verifying, failed(String), ready
    }
    private(set) var stage: Stage = .idle { didSet { let value = stage; DispatchQueue.main.async { self.onChange?(value) } } }
    var onChange: ((Stage) -> Void)?
    private let queue = DispatchQueue(label: "orator.setup", qos: .userInitiated)
    private var running = false

    static var runtime: URL { OratorPaths.support.appendingPathComponent("runtime", isDirectory: true) }
    static var python: URL { runtime.appendingPathComponent(".venv/bin/python") }
    static var marker: URL { runtime.appendingPathComponent(".installed-lock") }
    static var bundledRuntime: URL? { Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true) }
    static var uv: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uv") }

    static func lockDigest() -> String? {
        guard let lock = bundledRuntime?.appendingPathComponent("uv.lock"), let data = try? Data(contentsOf: lock) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static var engineReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        // Builds run from source without a bundled runtime keep whatever scripts/install.sh prepared.
        guard let digest = lockDigest() else { return true }
        return (try? String(contentsOf: marker, encoding: .utf8)) == digest
    }
    static func modelReady(at model: URL) -> Bool {
        FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors").path) &&
            FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path)
    }
    var canInstall: Bool { FileManager.default.isExecutableFile(atPath: Self.uv.path) && Self.bundledRuntime != nil }

    func run(model: URL, downloadModel: Bool, completion: @escaping (Bool) -> Void) {
        guard !running else { return }
        running = true
        queue.async {
            let success = self.perform(model: model, downloadModel: downloadModel)
            self.running = false
            DispatchQueue.main.async { completion(success) }
        }
    }

    private func perform(model: URL, downloadModel: Bool) -> Bool {
        do {
            try OratorPaths.prepare()
            if !Self.engineReady {
                stage = .installingEngine
                try installEngine()
            }
            if downloadModel && !Self.modelReady(at: model) {
                stage = .downloadingModel(nil)
                try fetchModel(model)
            }
            stage = .ready
            return true
        } catch {
            stage = .failed((error as NSError).domain)
            return false
        }
    }

    private func installEngine() throws {
        guard let bundled = Self.bundledRuntime, let digest = Self.lockDigest() else {
            throw NSError(domain: "This copy of Orator is missing its speech engine files. Download it again.", code: 1)
        }
        let files = FileManager.default
        // An install prepared before setup existed has no marker; adopt it if its engine already loads.
        if !files.fileExists(atPath: Self.marker.path), files.isExecutableFile(atPath: Self.python.path),
           (try? execute(Self.python, ["-c", "import parakeet_mlx, mlx.core"], environment: [:], timeout: 60)) == 0 {
            try digest.write(to: Self.marker, atomically: true, encoding: .utf8)
            return
        }
        try files.createDirectory(at: Self.runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["pyproject.toml", "uv.lock"] {
            let target = Self.runtime.appendingPathComponent(name)
            try? files.removeItem(at: target)
            try files.copyItem(at: bundled.appendingPathComponent(name), to: target)
        }
        let support = OratorPaths.support
        // Everything uv fetches (Python itself, wheels, cache) stays inside Orator's folder.
        let status = try execute(Self.uv, ["sync", "--project", Self.runtime.path, "--python", "3.12", "--locked", "--no-progress"],
                                 environment: ["UV_CACHE_DIR": support.appendingPathComponent("cache/uv").path,
                                               "UV_PYTHON_INSTALL_DIR": support.appendingPathComponent("python").path,
                                               "UV_PYTHON_PREFERENCE": "only-managed", "UV_NO_CONFIG": "1"],
                                 timeout: 1800)
        guard status == 0, files.isExecutableFile(atPath: Self.python.path) else {
            throw NSError(domain: "Installing the speech engine failed. Check your internet connection and try again.", code: 2)
        }
        try digest.write(to: Self.marker, atomically: true, encoding: .utf8)
    }

    private func fetchModel(_ model: URL) throws {
        guard let worker = Bundle.main.resourceURL?.appendingPathComponent("worker.py") else {
            throw NSError(domain: "This copy of Orator is missing its speech engine files. Download it again.", code: 3)
        }
        var expected: Double?
        let poll = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        poll.schedule(deadline: .now() + 0.5, repeating: 0.5)
        poll.setEventHandler { [weak self] in
            guard let self, let expected, expected > 0 else { return }
            self.stage = .downloadingModel(min(0.99, Double(Self.size(of: model)) / expected))
        }
        poll.resume()
        defer { poll.cancel() }
        let status = try execute(Self.python, ["-u", worker.path, "--download", "--model", model.path],
                                 environment: ["HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
                                               "DO_NOT_TRACK": "1"],
                                 timeout: 3600) { line in
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if object["event"] as? String == "size", let bytes = object["bytes"] as? Double { expected = bytes }
                if object["event"] as? String == "downloaded" { self.stage = .verifying }
            }
        }
        guard status == 0, Self.modelReady(at: model) else {
            throw NSError(domain: "Downloading the speech model failed. Check your internet connection and try again.", code: 4)
        }
    }

    private static func size(of folder: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let item as URL in items {
            total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    @discardableResult
    private func execute(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval,
                         onLine: ((String) -> Void)? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "TMPDIR": NSTemporaryDirectory()].merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            while let end = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer.prefix(upTo: end), as: UTF8.self)
                buffer.removeSubrange(...end)
                onLine?(line)
            }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        output.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}
