import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import OratorCore
import IOKit
import AppKit

private let outputLock = NSLock()
private func emit(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    outputLock.lock()
    defer { outputLock.unlock() }
    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

final class CaptureToken {
    let id: String
    let lock = NSLock()
    var cancelled = false
    var stopRequested = false
    var stopped = false
    init(_ id: String) { self.id = id }
    func stop(cancel: Bool) { lock.lock(); stopRequested = true; cancelled = cancelled || cancel; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
}

final class Recorder {
    let graph = DispatchQueue(label: "orator.capture.graph", qos: .userInitiated)
    let writer = DispatchQueue(label: "orator.capture.writer", qos: .userInitiated)
    let slots = DispatchSemaphore(value: 32)
    let tokenLock = NSLock()
    var token: CaptureToken?
    var engine: AVAudioEngine?
    var engineDeviceUID = ""
    var tapInstalled = false
    var captureGeneration: UUID?
    var recordingDevice: AudioDeviceID?
    var announcedRecording = false
    var graphStartedAt: UInt64 = 0
    var lastObservedSamples = 0
    var silentStartRetried = false
    var observer: NSObjectProtocol?
    var file: FileHandle?
    var converter: AVAudioConverter?
    var samples = 0
    var lastCheckpoint = 0
    var lastLevel = 0
    var zeroRun = 0
    var windowSquares = 0.0
    var windowSamples = 0
    var windows: [Double] = []
    var deviceInfo: [String: Any] = [:]
    var heardSignal = false
    var graphHeardSignal = false
    var live = false
    var liveRun = 0
    var zeroStreak = 0
    var reportedSilent = false
    var recovery: Recovery?
    var keepRecovery = true
    var timer: DispatchSourceTimer?
    var startedAt: UInt64 = 0
    var lastAudioAt: UInt64 = 0
    var failure: String?
    var configurationRestarts = 0
    var stopReason = "user"
    var shutdownAfterStop = false
    var queuedStart: [String: Any]?

    func request(_ request: [String: Any]) {
        guard let op = request["op"] as? String else { return }
        if op == "permissions" {
            reportPermissions()
            return
        }
        if op == "requestMicrophone" {
            DispatchQueue.main.async {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { _ in self.reportPermissions() }
                default: self.reportPermissions()
                }
            }
            return
        }
        if op == "prepare" {
            graph.async {
                self.tokenLock.lock(); let idle = self.token == nil; self.tokenLock.unlock()
                guard idle, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
                do { _ = try self.prepareEngine(request["device"] as? String ?? "") }
                catch { self.engine = nil }
            }
            return
        }
        if op == "shutdown" {
            tokenLock.lock(); let current = token; tokenLock.unlock()
            if let current {
                graph.async { self.shutdownAfterStop = true }
                stop(current.id, cancel: false)
            } else { exit(0) }
            return
        }
        guard let id = request["id"] as? String, UUID(uuidString: id) != nil else { return }
        if op == "start" {
            tokenLock.lock()
            if let busy = token, busy.shouldStop, queuedStart == nil {
                // The previous recording is only finalizing; start right after it instead of failing.
                queuedStart = request; tokenLock.unlock(); return
            }
            guard token == nil else { tokenLock.unlock(); emit(["event": "error", "id": id, "message": "Capture is busy"]); return }
            let current = CaptureToken(id); token = current; tokenLock.unlock()
            graph.async { self.start(request, current) }
        } else if op == "stop" || op == "cancel" {
            stop(id, cancel: op == "cancel")
        }
    }

    func reportPermissions() {
        let status: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default: status = "unknown"
        }
        emit(["event": "permissions", "microphone": status])
    }

    func prepareEngine(_ uid: String) throws -> AVAudioEngine {
        if let engine, engineDeviceUID == uid, let device = deviceID(uid),
           currentDevice(engine.inputNode.audioUnit) == device, transport(device) != "bluetooth" { return engine }
        let audio = AVAudioEngine()
        if !uid.isEmpty {
            guard let selectedDevice = deviceID(uid), let unit = audio.inputNode.audioUnit else {
                throw NSError(domain: "Selected microphone is unavailable", code: 3)
            }
            var device = selectedDevice
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &device,
                                             UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw NSError(domain: "Cannot select microphone", code: Int(status)) }
        }
        let input = audio.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw NSError(domain: "Microphone format is unavailable", code: 4)
        }
        // Allocate the graph ahead of key-down without starting microphone capture.
        audio.prepare()
        engine = audio; engineDeviceUID = uid
        return audio
    }

    func flushConverter(_ current: CaptureToken) {
        if let converter,
           let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                      channels: 1, interleaved: true),
           let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            var error: NSError?
            converter.convert(to: tail, error: &error) { _, status in
                status.pointee = .endOfStream; return nil
            }
            if error == nil { write(tail, current) }
        }
        converter = nil
    }

    func releaseEngine(_ current: CaptureToken) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false; engine = nil
        // Drain the old format before installing its replacement in the same recording.
        writer.sync {
            flushConverter(current)
            captureGeneration = nil; graphHeardSignal = false
        }
    }

    func startEngine(_ uid: String, _ current: CaptureToken) throws -> Bool {
        try CapturePolicy.retryStart(shouldStop: { current.shouldStop }) {
            do { try self.configureAndStart(uid, current) }
            catch { self.releaseEngine(current); throw error }
        }
    }

    func configureAndStart(_ uid: String, _ current: CaptureToken) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            current.stop(cancel: false)
            failure = "Microphone permission is required"
            return
        }
        let audio = try prepareEngine(uid)
        let input = audio.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                        channels: 1, interleaved: true),
              let conversion = AVAudioConverter(from: input, to: target) else {
            throw NSError(domain: "Microphone format is unavailable", code: 4)
        }
        let initialDevice = currentDevice(audio.inputNode.audioUnit)
        if let recordingDevice, initialDevice != recordingDevice {
            throw NSError(domain: "Microphone changed; captured audio is available to recover", code: 6)
        }
        recordingDevice = initialDevice
        let generation = UUID()
        writer.sync {
            converter = conversion; captureGeneration = generation; graphHeardSignal = false
            live = false; liveRun = 0; zeroStreak = 0; zeroRun = 0; reportedSilent = false
        }
        if let initialDevice {
            deviceInfo = ["transport": transport(initialDevice), "clamshell": lidClosed()]
        }
        audio.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self, weak current] buffer, _ in
            guard let self, let current else { return }
            guard self.slots.wait(timeout: .now()) == .success else {
                self.graph.async {
                    guard !current.shouldStop, self.captureGeneration == generation else { return }
                    self.failure = "Audio queue overflow; partial recording retained"; self.stop(current.id)
                }
                return
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.slots.signal(); return
            }
            copy.frameLength = buffer.frameLength
            let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<from.count {
                if let source = from[index].mData, let dest = to[index].mData {
                    memcpy(dest, source, Int(from[index].mDataByteSize))
                }
            }
            self.writer.async {
                defer { self.slots.signal() }
                self.consume(copy, current, target, conversion, generation: generation)
            }
        }
        tapInstalled = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                           object: audio, queue: nil) { [weak self] _ in
            self?.graph.async {
                guard let self else { return }
                self.tokenLock.lock(); let ownsToken = self.token === current; self.tokenLock.unlock()
                guard ownsToken, self.engine === audio, !current.stopped,
                      !current.shouldStop else { return }
                let actualFormat = audio.inputNode.outputFormat(forBus: 0)
                let currentHardware = currentDevice(audio.inputNode.audioUnit)
                let changedDevice = initialDevice != nil && currentHardware != nil && initialDevice != currentHardware
                let sameFormat = actualFormat.sampleRate == input.sampleRate &&
                                 actualFormat.channelCount == input.channelCount
                switch CapturePolicy.configurationChange(running: audio.isRunning,
                    formatUnchanged: sameFormat, deviceChanged: changedDevice,
                    restarts: self.configurationRestarts) {
                case .keepRecording: break
                case .restartOnce:
                    self.recover(current)
                case .interrupt:
                    self.failure = changedDevice ? "Microphone changed; captured audio is available to recover" :
                        "Audio configuration changed repeatedly; captured audio is available to recover"
                    self.stop(current.id)
                }
            }
        }
        guard !current.shouldStop else { return }
        audio.prepare()
        try writer.sync {
            try audio.start()
            graphStartedAt = DispatchTime.now().uptimeNanoseconds
            lastAudioAt = graphStartedAt; lastObservedSamples = samples
            if !announcedRecording {
                startedAt = graphStartedAt; announcedRecording = true
                emit(["event": "recording", "id": current.id].merging(deviceInfo) { a, _ in a })
            }
        }
    }

    func recover(_ current: CaptureToken) {
        tokenLock.lock(); let ownsToken = token === current; tokenLock.unlock()
        guard ownsToken, !current.shouldStop, !current.stopped else { return }
        guard configurationRestarts < CapturePolicy.maxConfigurationRestarts else {
            failure = "Microphone stopped delivering audio; captured audio is available to recover"
            stop(current.id); return
        }
        configurationRestarts += 1
        let uid = engineDeviceUID
        releaseEngine(current)
        emit(["event": "recovering", "id": current.id, "attempt": configurationRestarts])
        do {
            let started = try startEngine(uid, current)
            if !started || current.shouldStop { stop(current.id, cancel: current.isCancelled) }
        } catch {
            let detail = error as NSError
            failure = "Microphone recovery failed (\(detail.domain), \(detail.code)); captured audio is available to recover"
            stop(current.id)
        }
    }

    func start(_ request: [String: Any], _ current: CaptureToken) {
        do {
            samples = 0; lastCheckpoint = 0; lastLevel = 0; failure = nil
            zeroRun = 0; heardSignal = false; reportedSilent = false
            live = false; liveRun = 0; zeroStreak = 0
            windowSquares = 0; windowSamples = 0; windows = []; deviceInfo = [:]
            configurationRestarts = 0; stopReason = "user"
            recordingDevice = nil; announcedRecording = false; silentStartRetried = false
            startedAt = 0; graphStartedAt = 0; lastObservedSamples = 0
            keepRecovery = !(request["neverStore"] as? Bool ?? false)
            guard !current.shouldStop else { finish(current, cancelled: current.isCancelled); return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw NSError(domain: "Microphone permission is required", code: 1)
            }
            try OratorPaths.prepare()
            keepRecovery = !(request["neverStore"] as? Bool ?? false)
            recovery = Recovery(id: current.id)
            if keepRecovery { try checkpoint() }
            let path = OratorPaths.pcm(current.id)
            guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "Cannot create private recording", code: 2)
            }
            file = try FileHandle(forWritingTo: path)
            samples = 0; lastCheckpoint = 0; failure = nil
            let started: Bool
            do { started = try startEngine(request["device"] as? String ?? "", current) }
            catch {
                let detail = error as NSError
                let holders = microphoneHolders()
                let hint = holders.isEmpty ? "Try again or pick another input in Settings." :
                    "\(holders.prefix(3).joined(separator: ", ")) may be using it."
                throw NSError(domain: "Microphone unavailable (\(detail.domain), \(detail.code)). \(hint)", code: 5)
            }
            guard started, !current.shouldStop else { stop(current.id, cancel: current.isCancelled); return }
            let maxSeconds = min(1200, max(10, request["maxSeconds"] as? Int ?? 300))
            let timer = DispatchSource.makeTimerSource(queue: graph)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard !current.shouldStop, !current.stopped else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(now - self.startedAt) / 1e9
                if elapsed >= Double(maxSeconds) {
                    self.stopReason = "limit"
                    self.stop(current.id)
                    return
                }
                let health = self.writer.sync { (self.samples, self.graphHeardSignal) }
                if health.0 != self.lastObservedSamples {
                    self.lastObservedSamples = health.0; self.lastAudioAt = now
                }
                if CapturePolicy.needsAudioRecovery(callbackAge: Double(now - self.lastAudioAt) / 1e9,
                    startupAge: Double(now - self.graphStartedAt) / 1e9, heardSignal: health.1,
                    silentStartRetried: self.silentStartRetried) {
                    if !health.1 { self.silentStartRetried = true }
                    self.recover(current)
                }
            }
            self.timer = timer; timer.resume()
        } catch {
            failure = (error as NSError).domain
            stop(current.id)
        }
    }

    func consume(_ input: AVAudioPCMBuffer, _ current: CaptureToken, _ target: AVAudioFormat,
                 _ converter: AVAudioConverter, generation: UUID) {
        guard captureGeneration == generation, recovery?.id == current.id, file != nil else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil else {
            graph.async {
                guard !current.shouldStop, self.captureGeneration == generation else { return }
                self.failure = "Audio conversion failed"; self.stop(current.id)
            }
            return
        }
        write(converted, current)
    }

    func write(_ buffer: AVAudioPCMBuffer, _ current: CaptureToken) {
        guard buffer.frameLength > 0, let pointer = buffer.int16ChannelData?[0] else { return }
        do {
            let count = Int(buffer.frameLength)
            try file?.write(contentsOf: Data(bytes: pointer, count: count * 2))
            samples += count
            for i in 0..<count { let value = Double(pointer[i]) / 32768; windowSquares += value * value }
            windowSamples += count
            if windowSamples >= 4000 {
                if windows.count < 4800 { windows.append(sqrt(windowSquares / Double(windowSamples))) }
                windowSquares = 0; windowSamples = 0
            }
            if !live {
                // Built-in microphones deliver exact zeros while powering up; only real audio means "speak now".
                for i in 0..<count {
                    if pointer[i] == 0 { zeroStreak += 1; if zeroStreak >= CapturePolicy.warmupZeroRun { liveRun = 0 } }
                    else { zeroStreak = 0; liveRun += 1 }
                }
                if liveRun >= CapturePolicy.liveSamples {
                    live = true
                    let warmup = Double(DispatchTime.now().uptimeNanoseconds - graphStartedAt) / 1e9
                    emit(["event": "live", "id": current.id, "warmup": warmup, "atSample": max(0, samples - liveRun)])
                }
            }
            var lastNonZero = -1
            for i in stride(from: count - 1, through: 0, by: -1) where pointer[i] != 0 { lastNonZero = i; break }
            if lastNonZero >= 0 {
                heardSignal = true; graphHeardSignal = true; zeroRun = count - 1 - lastNonZero
                if reportedSilent { reportedSilent = false; emit(["event": "silent", "id": current.id, "silent": false]) }
            } else {
                zeroRun += count
                if zeroRun >= CapturePolicy.silentSamples && !reportedSilent {
                    reportedSilent = true; emit(["event": "silent", "id": current.id, "silent": true])
                }
            }
            if samples - lastLevel >= 1600 {
                // Ten level updates a second keep the live waveform responsive.
                var sum = 0.0
                for i in 0..<count { let value = Double(pointer[i]) / 32768; sum += value * value }
                emit(["event": "level", "id": current.id, "level": sqrt(sum / Double(count)),
                      "seconds": Double(samples) / 16000])
                lastLevel = samples
            }
            if samples - lastCheckpoint >= 4000 {
                lastCheckpoint = samples
                recovery?.samples = samples
                if keepRecovery { try checkpoint() }
            }
        } catch {
            graph.async { self.failure = "Cannot write recording; check free disk space"; self.stop(current.id) }
        }
    }

    func checkpoint() throws {
        if let recovery {
            try JSONEncoder().encode(recovery).write(to: OratorPaths.manifest(recovery.id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: OratorPaths.manifest(recovery.id).path)
        }
    }

    func stop(_ id: String, cancel: Bool = false) {
        tokenLock.lock(); let current = token; tokenLock.unlock()
        guard let current, current.id == id else { return }
        current.stop(cancel: cancel)
        graph.async {
            guard !current.stopped else { return }
            current.stopped = true
            self.timer?.cancel(); self.timer = nil
            if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
            self.observer = nil
            if let engine = self.engine {
                if self.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
                self.tapInstalled = false
                engine.stop()
                if self.failure == nil && self.deviceInfo["transport"] as? String != "bluetooth" {
                    engine.prepare()
                } else { self.engine = nil }
            }
            self.writer.async {
                self.flushConverter(current)
                self.captureGeneration = nil
                do { try self.file?.synchronize(); try self.file?.close() }
                catch { self.failure = "Recording finalization failed; partial audio retained" }
                self.file = nil
                self.recovery?.samples = self.samples
                self.recovery?.failureReason = self.failure
                if self.keepRecovery {
                    do { try self.checkpoint() }
                    catch { self.failure = "Cannot save recovery metadata; check free disk space" }
                }
                self.finish(current, cancelled: current.isCancelled)
            }
        }
    }

    func finish(_ current: CaptureToken, cancelled: Bool) {
        let count = samples
        let message = failure
        if cancelled || (!keepRecovery && shutdownAfterStop) { OratorPaths.remove(current.id) }
        tokenLock.lock(); if token?.id == current.id { token = nil }
        let next = queuedStart; queuedStart = nil; tokenLock.unlock()
        if cancelled {
            emit(["event": "cancelled", "id": current.id])
        } else if let message {
            emit(["event": "interrupted", "id": current.id, "samples": count, "message": message])
        } else {
            var stopped: [String: Any] = ["event": "stopped", "id": current.id, "samples": count,
                                          "reason": stopReason, "silent": !heardSignal]
            if let quality = AudioQuality.assess(windows) {
                stopped["speechDB"] = quality.speechDB; stopped["snrDB"] = quality.snrDB; stopped["poorQuality"] = quality.poor
            }
            emit(stopped)
        }
        if shutdownAfterStop { exit(0) }
        if let next { request(next) }
    }
}

private func currentDevice(_ unit: AudioUnit?) -> AudioDeviceID? {
    guard let unit else { return nil }
    var value: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                               0, &value, &size) == noErr, value != 0 else { return nil }
    return value
}

private func transport(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
    switch value {
    case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
    default: return "other"
    }
}

/// The built-in microphone is disconnected in hardware while the lid is closed.
private func lidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool ?? false
}

/// Apps currently recording from any input, from Core Audio's process objects (macOS 14+).
private func microphoneHolders() -> [String] {
    func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return [] }
    let ownParent = getppid(), own = getpid()
    var names: [String] = []
    for process in processes where (property(process, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
        guard let raw = property(process, kAudioProcessPropertyPID) else { continue }
        let pid = pid_t(bitPattern: raw)
        guard pid > 0, pid != own, pid != ownParent else { continue }
        var name = NSRunningApplication(processIdentifier: pid)?.localizedName
        if name == nil {
            var buffer = [CChar](repeating: 0, count: 1024)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { name = String(cString: buffer) }
        }
        // Siri's always-on listener is not a competing recorder.
        if let name, name != "corespeechd", !names.contains(name) { names.append(name) }
    }
    return names
}

private func deviceID(_ uid: String) -> AudioDeviceID? {
    if uid.isEmpty {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
    for device in devices {
        var value: Unmanaged<CFString>?
        var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &property, 0, nil, &length, &value) == noErr,
           let value, value.takeRetainedValue() as String == uid { return device }
    }
    return nil
}

private let recorder = Recorder()
signal(SIGPIPE, SIG_IGN)
// If Orator dies without closing our stdin, reparenting to launchd still releases the microphone.
private let orphanWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
orphanWatch.schedule(deadline: .now() + 2, repeating: 2)
orphanWatch.setEventHandler { if getppid() == 1 { recorder.request(["op": "shutdown"]) } }
orphanWatch.resume()
emit(["event": "ready"])
recorder.reportPermissions()
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        guard line.utf8.count <= 65536, let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        recorder.request(request)
    }
    recorder.request(["op": "shutdown"])
}
RunLoop.main.run()
