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

private final class CaptureToken {
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

private final class Recorder {
    let graph = DispatchQueue(label: "orator.capture.graph", qos: .userInitiated)
    let writer = DispatchQueue(label: "orator.capture.writer", qos: .userInitiated)
    let slots = DispatchSemaphore(value: 32)
    let tokenLock = NSLock()
    var token: CaptureToken?
    var engine: AVAudioEngine?
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

    func start(_ request: [String: Any], _ current: CaptureToken) {
        do {
            samples = 0; lastCheckpoint = 0; lastLevel = 0; failure = nil
            zeroRun = 0; heardSignal = false; reportedSilent = false
            windowSquares = 0; windowSamples = 0; windows = []; deviceInfo = [:]
            configurationRestarts = 0; stopReason = "user"
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
            let audio = AVAudioEngine()
            engine = audio
            if let uid = request["device"] as? String, !uid.isEmpty {
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
            guard input.sampleRate > 0, input.channelCount > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: true),
                  let conversion = AVAudioConverter(from: input, to: target) else {
                throw NSError(domain: "Microphone format is unavailable", code: 4)
            }
            converter = conversion
            let initialDevice = currentDevice(audio.inputNode.audioUnit)
            if let initialDevice {
                deviceInfo = ["transport": transport(initialDevice), "clamshell": lidClosed()]
            }
            audio.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self, weak current] buffer, _ in
                guard let self, let current else { return }
                guard self.slots.wait(timeout: .now()) == .success else {
                    self.graph.async { self.failure = "Audio queue overflow; partial recording retained"; self.stop(current.id) }
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
                    self.consume(copy, current, target)
                }
            }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: audio, queue: nil) { [weak self] _ in
                self?.graph.async {
                    guard let self, self.token?.id == current.id, !current.stopped,
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
                        self.configurationRestarts += 1
                        do { audio.prepare(); try audio.start() }
                        catch {
                            self.failure = "Audio engine could not recover its configuration"
                            self.stop(current.id)
                        }
                    case .interrupt:
                        self.failure = "Audio device or format changed; captured audio is available to recover"
                        self.stop(current.id)
                    }
                }
            }
            guard !current.shouldStop else { stop(current.id, cancel: current.isCancelled); return }
            var retries = CapturePolicy.startRetryDelays[...]
            while true {
                do { audio.prepare(); try audio.start(); break }
                catch {
                    guard let delay = retries.popFirst(), !current.shouldStop else {
                        let holders = microphoneHolders()
                        throw NSError(domain: holders.isEmpty ? "Microphone unavailable. The audio driver may be stuck; try again or pick another input." :
                            "Microphone unavailable. \(holders.prefix(3).joined(separator: ", ")) may be using it.", code: 5)
                    }
                    usleep(UInt32(delay * 1_000_000))
                    guard !current.shouldStop else { stop(current.id, cancel: current.isCancelled); return }
                }
            }
            startedAt = DispatchTime.now().uptimeNanoseconds
            lastAudioAt = startedAt
            let maxSeconds = min(1200, max(10, request["maxSeconds"] as? Int ?? 300))
            let timer = DispatchSource.makeTimerSource(queue: graph)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.startedAt) / 1e9
                if elapsed >= Double(maxSeconds) {
                    self.stopReason = "limit"
                    self.stop(current.id)
                }
            }
            self.timer = timer; timer.resume()
        } catch {
            failure = (error as NSError).domain
            stop(current.id)
        }
    }

    func consume(_ input: AVAudioPCMBuffer, _ current: CaptureToken, _ target: AVAudioFormat) {
        guard let converter, file != nil else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil else {
            graph.async { self.failure = "Audio conversion failed"; self.stop(current.id) }
            return
        }
        write(converted, current)
    }

    func write(_ buffer: AVAudioPCMBuffer, _ current: CaptureToken) {
        guard buffer.frameLength > 0, let pointer = buffer.int16ChannelData?[0] else { return }
        do {
            let count = Int(buffer.frameLength)
            try file?.write(contentsOf: Data(bytes: pointer, count: count * 2))
            let wasEmpty = samples == 0
            samples += count
            if wasEmpty { emit(["event": "recording", "id": current.id].merging(deviceInfo) { a, _ in a }) }
            for i in 0..<count { let value = Double(pointer[i]) / 32768; windowSquares += value * value }
            windowSamples += count
            if windowSamples >= 4000 {
                if windows.count < 4800 { windows.append(sqrt(windowSquares / Double(windowSamples))) }
                windowSquares = 0; windowSamples = 0
            }
            var lastNonZero = -1
            for i in stride(from: count - 1, through: 0, by: -1) where pointer[i] != 0 { lastNonZero = i; break }
            if lastNonZero >= 0 {
                heardSignal = true; zeroRun = count - 1 - lastNonZero
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
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            self.engine = nil
            self.writer.async {
                if let converter = self.converter,
                   let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                              channels: 1, interleaved: true),
                   let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
                    var error: NSError?
                    converter.convert(to: tail, error: &error) { _, status in
                        status.pointee = .endOfStream; return nil
                    }
                    if error == nil { self.write(tail, current) }
                }
                self.converter = nil
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
