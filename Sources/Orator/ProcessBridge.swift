import Foundation
import OratorCore
import Darwin

final class ProcessBridge {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = UUID()
    private let reader = DispatchQueue(label: "orator.protocol")
    private var budget = RestartBudget()
    var onMessage: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var running: Bool { process?.isRunning == true }
    var processID: pid_t? { process?.processIdentifier }

    func launch(_ executable: URL, arguments: [String] = []) throws {
        stop()
        let now = ProcessInfo.processInfo.systemUptime
        guard budget.canStart(now: now) else {
            throw NSError(domain: "Repeated component failures. Use Restart services.", code: 1)
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        let current = UUID()
        generation = current
        child.executableURL = executable
        child.arguments = arguments
        let env = ProcessInfo.processInfo.environment
        child.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "TMPDIR": env["TMPDIR"] ?? NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "DO_NOT_TRACK": "1", "TOKENIZERS_PARALLELISM": "false"
        ]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        var parser = JSONLineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.reader.async { [weak self] in
                do {
                    let messages = try parser.append(data)
                    DispatchQueue.main.async {
                        guard let self, self.generation == current else { return }
                        for message in messages { self.onMessage?(message) }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.generation == current else { return }
                        self.budget.recordFailure(now: ProcessInfo.processInfo.systemUptime)
                        self.stop()
                        self.onExit?()
                    }
                }
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.budget.recordFailure(now: ProcessInfo.processInfo.systemUptime)
                self.output?.readabilityHandler = nil
                self.process = nil; self.input = nil; self.output = nil
                self.onExit?()
            }
        }
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do { try child.run() }
        catch {
            budget.recordFailure(now: ProcessInfo.processInfo.systemUptime)
            stop(); throw error
        }
    }

    @discardableResult func send(_ message: [String: Any]) -> Bool {
        guard running, let input, let data = try? JSONSerialization.data(withJSONObject: message),
              data.count < 65536 else { return false }
        do { try input.write(contentsOf: data + Data([10])); return true }
        catch { return false }
    }

    func resetFailures() { budget = RestartBudget() }
    func stop(completion: (() -> Void)? = nil) {
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil; output = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().async {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
                if process.isRunning { kill(pid, SIGKILL) }
                process.waitUntilExit()
                if let completion { DispatchQueue.main.async(execute: completion) }
            }
        } else if let completion {
            DispatchQueue.main.async(execute: completion)
        }
        process = nil
    }
    deinit { stop() }
}
