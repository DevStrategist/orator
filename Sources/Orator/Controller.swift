import AppKit
import AVFoundation
import Carbon
import Combine
import ServiceManagement
import OratorCore

final class Controller: NSObject, ObservableObject {
    @Published var settings = Settings() {
        didSet {
            guard loaded else { return }
            do {
                try JSONEncoder().encode(settings).write(to: OratorPaths.settings, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OratorPaths.settings.path)
            } catch { message = "Could not save settings. Check disk space and permissions." }
            if settings.neverStore && !oldValue.neverStore {
                discard()
                cleanOrphans()
                message = "Audio retention disabled; pending recovery recordings deleted."
            }
            configureKeys()
        }
    }
    private func sendCapture(_ request: [String: Any]) -> Bool {
        captureRequestOverride?(request) ?? capture.send(request)
    }
    @Published var phase: Phase = .idle
    @Published var message = "Starting local services…"
    @Published var modelReady = false
    @Published var captureReady = false
    @Published var shortcutReady = false
    @Published var accessibility = false
    @Published var permissionEvidence = PermissionEvidence()
    @Published var permissionRequest = PermissionRequest()
    @Published var shortcutStatus = "Waiting for Accessibility permission"
    @Published var permissionsCheckedAt: Date?
    @Published var microphone = false
    @Published var captureMicrophoneStatus = "unknown"
    @Published var secureInput = false
    @Published var fnKeyAvailable = true
    @Published var silentInput = false
    @Published var micLive = false
    private var micWarmup = 0.0
    @Published var handsFree = false
    @Published var lowSignal = false
    @Published var undoAvailable = false
    private var quietSince: Double?
    private var undoSession: (id: String, target: TargetSnapshot?, settings: Settings)?
    private var undoTimer: Timer?
    let outputMute = OutputMute()
    let setup = RuntimeSetup()
    @Published var setupStage: RuntimeSetup.Stage = .idle
    let mediaPause = MediaPause()
    @Published var lidBlocksMicrophone = false
    @Published var noticeAction: (label: String, run: () -> Void)?
    private var inputTransport = ""
    private var editWatch: Timer?
    var gesture = PushToTalkGesture()
    private var holdStartedAt = 0.0
    private var pendingTip: String?
    @Published var level = 0.0
    @Published var seconds = 0.0
    @Published var lastText = ""
    @Published var notice: String?
    @Published var lastFailureReason: String?
    @Published var recoveries: [Recovery] = []
    @Published var devices: [(id: String, name: String)] = []
    @Published var recordingShortcut = false { didSet { configureKeys() } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?
    var showWindow: (() -> Void)?
    var targetProvider: () -> TargetSnapshot? = TargetSnapshot.capture
    var captureRequestOverride: (([String: Any]) -> Bool)?
    var relaunchApplication: (() -> Void)?
    let capture = ProcessBridge(), worker = ProcessBridge()
    let keys = Hotkeys(), insertion = Insertion()
    var machine = SessionMachine()
    var target: TargetSnapshot?
    var lastTextSessionID: String?
    var menuTarget: TargetSnapshot?
    var sessionSettings = Settings()
    var watchdog: Timer?
    var lastEvent = ProcessInfo.processInfo.systemUptime
    var workerStarted = 0.0
    var captureStarted = 0.0
    var phaseStarted = 0.0
    var lastTick = ProcessInfo.processInfo.systemUptime
    var lastRecoverySweep = ProcessInfo.processInfo.systemUptime
    private var lastTapAttempt = -10.0
    private var permissionObservers: [NSObjectProtocol] = []
    var shuttingDown = false
    var sleeping = false
    var loaded = false
    private var servicesEnabled = true
    var shortcutMonitor: Any?
    private var noticeTimer: Timer?
    private var pendingMicrophoneRequest = false
    private var lastPermissionPoll = -10.0
    private var startAttempts = 0
    private var acceptedStarts = 0
    private var earlyReleases = 0
    private var captureStartLatency = 0.0
    private var captureBeganAt = 0.0
    private(set) var captureDiagnostic = "notRequested"
    private var diagnosticSessionID: String?
    private var diagnosticStartedAt = 0.0
    private var diagnosticSamples = 0
    private var diagnosticDetail = ""
    private var textInsertionDiagnostic = "notRequested"
    private var textDiagnosticToken = UUID()
    static let maxPendingRecoveries = 3
    init(startServices: Bool = true) {
        super.init()
        servicesEnabled = startServices
        guard startServices else { return }
        do { try OratorPaths.prepare() } catch { message = "Cannot create private application storage." }
        if let data = try? Data(contentsOf: OratorPaths.settings),
           var saved = try? JSONDecoder().decode(Settings.self, from: data) {
            saved.validate(); settings = saved
        }
        loaded = true
        if settings.neverStore {
            for entry in OratorPaths.recoveries() { OratorPaths.remove(entry.id) }
            cleanOrphans()
        }
        refreshRecovery(); refreshDevices()
        capture.onMessage = { [weak self] in self?.captureMessage($0) }
        worker.onMessage = { [weak self] in self?.workerMessage($0) }
        capture.onExit = { [weak self] in self?.componentExited(model: false) }
        worker.onExit = { [weak self] in self?.componentExited(model: true) }
        setup.onChange = { [weak self] stage in
            guard let self else { return }
            self.setupStage = stage
            if case .failed(let reason) = stage { self.message = reason }
            self.onChange?()
        }
        keys.onDown = { [weak self] in self?.keyDown() }
        keys.onUp = { [weak self] in self?.keyUp() }
        keys.onChord = { [weak self] in self?.chordDuringStart() }
        keys.onSecureBlocked = { [weak self] in
            let owner = NativePermissions.secureInputOwner().map { "\($0) has" } ?? "An app has"
            self?.showNotice("Shortcut blocked: \(owner) Secure Keyboard Entry on. Leave its password field, or quit and reopen it.")
        }
        outputMute.recoverAfterCrash()
        keys.onCancel = { [weak self] in self?.cancelWithUndo() }
        keys.onStatus = { [weak self] ready, detail in
            self?.shortcutReady = ready
            self?.shortcutStatus = detail
        }
        configureKeys()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        permissionObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.permissionsChanged() })
        permissionObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] _ in self?.permissionsChanged() })
        permissionObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.permissionsChanged() })
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        startCapture(); startWorker()
        refreshPermissions()
        Cues.preload()
    }

    func cleanOrphans() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: OratorPaths.recordings,
                                                    includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "pcm" {
            let id = entry.deletingPathExtension().lastPathComponent
            if UUID(uuidString: id) != nil && !FileManager.default.fileExists(atPath: OratorPaths.manifest(id).path) {
                OratorPaths.remove(id)
            }
        }
    }
    var busy: Bool { phase != .idle && phase != .failed }
    var hudPhase: Bool { [.starting, .recording, .stopping, .transcribing].contains(phase) }
    struct SetupItem {
        let title: String
        let detail: String
        let action: String?
        var progress: Double? = nil
        let run: () -> Void
    }
    /// What still stands between the user and a working shortcut, in the order to fix it.
    var setupItems: [SetupItem] {
        var items: [SetupItem] = []
        if !microphone {
            items.append(SetupItem(title: "Microphone access", detail: "So Orator can hear you.",
                                   action: "Allow") { [weak self] in self?.requestMicrophone() })
        }
        if !accessibility {
            items.append(SetupItem(title: "Accessibility access", detail: "So Orator can type into other apps.",
                                   action: "Open Settings") { [weak self] in self?.requestAccessibility() })
        } else if !shortcutReady {
            items.append(SetupItem(title: "Keyboard shortcut", detail: shortcutStatus,
                                   action: "Fix") { [weak self] in self?.configureShortcutAccess() })
        }
        if !modelReady {
            let retry = { [weak self] in self?.startWorker(); return }
            switch setupStage {
            case .installingEngine:
                items.append(SetupItem(title: "Installing the speech engine",
                                       detail: "One time only, about 550 MB. Everything stays in Orator's own folder.",
                                       action: nil, run: retry))
            case .downloadingModel(let fraction):
                items.append(SetupItem(title: "Downloading the speech model",
                                       detail: fraction.map { "\(Int($0 * 100))% of 755 MB. After this, Orator works offline." } ??
                                           "Starting the 755 MB download. After this, Orator works offline.",
                                       action: nil, progress: fraction, run: retry))
            case .verifying:
                items.append(SetupItem(title: "Checking the speech model", detail: "Verifying the download.", action: nil, run: retry))
            case .failed(let reason):
                items.append(SetupItem(title: "Speech engine setup stopped", detail: reason, action: "Try again", run: retry))
            default:
                items.append(SetupItem(title: "Speech model", detail: worker.running ? "Loading the on-device model." : message,
                                       action: worker.running ? nil : "Restart") { [weak self] in self?.restart() })
            }
        }
        if !captureReady && !capture.running {
            items.append(SetupItem(title: "Audio capture", detail: "The capture service stopped.",
                                   action: "Restart") { [weak self] in self?.restart() })
        }
        return items
    }
    var needsAttention: Bool { !microphone || !accessibility || !shortcutReady || permissionGuidance != nil }
    var recordingHint: String? {
        if lidBlocksMicrophone { return "The lid is closed: the built-in mic can't hear you." }
        if silentInput { return "No microphone signal. Check mute or the selected input." }
        if lowSignal { return "No audio received. Check your microphone or its input level." }
        let remaining = Double(sessionSettings.maxSeconds) - seconds
        if phase == .recording && remaining <= 30 { return "Recording stops in \(max(0, Int(remaining)))s" }
        return nil
    }
    func configureKeys() {
        keys.configure(settings.hotkey, active: busy, paused: recordingShortcut || sleeping)
    }
    func publish() {
        phase = machine.phase
        if ![.starting, .recording].contains(phase) { handsFree = false; outputMute.restore(); mediaPause.resume() }
        configureKeys()
        onChange?()
    }
    func startCapture() {
        guard !shuttingDown, !sleeping else { return }
        captureReady = false
        microphone = false
        captureMicrophoneStatus = "unknown"
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OratorCapture.app/Contents/MacOS/OratorCapture")
        do {
            captureStarted = ProcessInfo.processInfo.systemUptime
            try capture.launch(path)
        } catch { message = "Capture service unavailable: \((error as NSError).domain)" }
    }
    func startWorker() {
        guard !shuttingDown, !sleeping else { return }
        modelReady = false
        let python = RuntimeSetup.python
        let script = Bundle.main.resourceURL!.appendingPathComponent("worker.py")
        let customModel = !settings.modelPath.isEmpty
        let model = customModel ? (settings.modelPath as NSString).expandingTildeInPath : OratorPaths.model.path
        let modelURL = URL(fileURLWithPath: model)
        if !RuntimeSetup.engineReady || (!customModel && !RuntimeSetup.modelReady(at: modelURL)) {
            guard setup.canInstall else {
                message = "The speech engine is not installed. Run scripts/install.sh from the project."; return
            }
            setup.run(model: modelURL, downloadModel: !customModel) { [weak self] success in
                if success { self?.startWorker() }
            }
            return
        }
        guard RuntimeSetup.modelReady(at: modelURL) else {
            message = "No speech model was found in the chosen model folder."; return
        }
        do {
            workerStarted = ProcessInfo.processInfo.systemUptime
            try worker.launch(python, arguments: ["-u", script.path, "--model", model,
                                                  "--recordings", OratorPaths.recordings.path])
        } catch { message = "Model service unavailable: \((error as NSError).domain)" }
    }
    func componentExited(model: Bool) {
        if model { modelReady = false } else { captureReady = false }
        guard !shuttingDown, !sleeping else { return }
        if busy { fail(model ? "Local model stopped; audio retained for retry." : "Capture service stopped; partial audio retained.") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.shuttingDown, !self.sleeping else { return }
            if model { self.startWorker() } else { self.startCapture() }
        }
    }
    func refreshPermissions() {
        guard !shuttingDown else { return }
        let previous = permissionEvidence
        let evidence = NativePermissions.sample()
        permissionEvidence = evidence
        accessibility = evidence.accessibilityTrusted
        let now = ProcessInfo.processInfo.systemUptime
        if capture.running && now - lastPermissionPoll >= 2 {
            lastPermissionPoll = now
            capture.send(["op": "permissions"])
        }
        secureInput = IsSecureEventInputEnabled()
        permissionsCheckedAt = Date()
        permissionRequest.refresh(evidence, now: ProcessInfo.processInfo.systemUptime)
        if previous.accessibilityOperational && !evidence.accessibilityOperational && busy {
            fail("Accessibility access was revoked. Dictation stopped safely.")
        }
        let mode = evidence.shortcutTapMode
        if mode != .unavailable && !sleeping {
            // A revoked grant leaves the active tap disabled; rebuild it as listen-only.
            if keys.mode == .active && mode != .active { keys.stop() }
            if now - lastTapAttempt >= 2 {
                lastTapAttempt = now
                keys.start(mode)
            }
        } else {
            if keys.available { keys.stop() }
            shortcutReady = false
            shortcutStatus = accessibility ? "macOS granted access, but the native AX check is denied" :
                                             "Accessibility or Input Monitoring permission is required"
        }
        writeDiagnostics()
    }
    func permissionsChanged() {
        refreshPermissions()
        // Give System Settings time to commit changes before a second native check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.refreshPermissions()
        }
    }
    var permissionGuidance: String? {
        if let pending = permissionRequest.pending {
            return pending == .accessibility ?
                "Waiting for macOS. Enable Orator in Accessibility; this window rechecks automatically." :
                "Waiting for macOS Input Monitoring. It is separate from Accessibility and optional for the default shortcut."
        }
        if let expired = permissionRequest.timedOut {
            return expired == .accessibility ?
                "Permission has not been detected. If Orator is already enabled, remove its old Accessibility entry and add this installed app again. A stale grant from the earlier unsigned build can remain checked." :
                "Input Monitoring has not been detected. Enable this installed Orator in that pane, then recheck. macOS may require a relaunch for keyboard monitoring."
        }
        if accessibility && permissionEvidence.accessibilityProbe == .denied {
            return "macOS reports Accessibility granted, but native access is denied. Recheck, or relaunch Orator; if it persists, remove the old entry and add this installed app."
        }
        return nil
    }
    func requestMicrophone() {
        guard captureReady else {
            pendingMicrophoneRequest = true
            if !capture.running { startCapture() }
            return
        }
        capture.send(["op": "requestMicrophone"])
        if ["denied", "restricted"].contains(captureMicrophoneStatus) {
            openPrivacy("Microphone")
        }
    }
    func requestAccessibility() {
        refreshPermissions()
        guard !accessibility else { openPrivacy("Accessibility"); return }
        permissionRequest.begin(.accessibility, now: ProcessInfo.processInfo.systemUptime)
        _ = NativePermissions.accessibilityTrusted(prompt: true)
        // The native request is asynchronous: never mark granted from opening the pane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openPrivacy("Accessibility")
            self?.permissionsChanged()
        }
    }
    func requestInputMonitoring() {
        refreshPermissions()
        guard !permissionEvidence.inputMonitoringAllowed else { openPrivacy("ListenEvent"); return }
        permissionRequest.begin(.inputMonitoring, now: ProcessInfo.processInfo.systemUptime)
        NativePermissions.requestInputMonitoring()
        openPrivacy("ListenEvent")
        permissionsChanged()
    }
    func configureShortcutAccess() {
        guard !busy else { message = "Finish or cancel dictation before restarting keyboard access."; return }
        refreshPermissions()
        if !accessibility { requestAccessibility() }
        else {
            lastTapAttempt = -10
            keys.stop()
            permissionsChanged()
        }
    }
    func revealInstalledApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices.map { ($0.uniqueID, $0.localizedName) }
        fnKeyAvailable = FnKeyPolicy.available(Hotkeys.keyboards())
    }
    func keyDown() {
        let recordingNow = phase == .starting || phase == .recording
        if recordingNow ? sessionSettings.toggleMode : settings.toggleMode {
            if recordingNow { stopRecording() } else { begin(target: captureDiagnostic == "running" ? nil : targetProvider()) }
            return
        }
        // A session started from the menu has no gesture; the shortcut simply finishes it.
        if recordingNow && !gesture.active { stopRecording(); return }
        // The gesture belongs to the session; begin() may publish while clearing an old failure.
        if !recordingNow { gesture.reset() }
        switch gesture.press(now: ProcessInfo.processInfo.systemUptime) {
        case .start:
            holdStartedAt = ProcessInfo.processInfo.systemUptime
            begin(target: captureDiagnostic == "running" ? nil : targetProvider())
            if phase != .starting { gesture.reset() }
        case .lock:
            handsFree = true; onChange?()
        case .stop:
            stopRecording()
        default: break
        }
    }
    func keyUp() {
        guard !sessionSettings.toggleMode else { return }
        guard phase == .starting || phase == .recording, gesture.active else { gesture.reset(); return }
        let now = ProcessInfo.processInfo.systemUptime
        switch gesture.release(now: now) {
        case .stop:
            if now - holdStartedAt >= 60 && tipDue("handsFree", every: 7 * 86400) {
                pendingTip = "Tip: double-tap \(settings.hotkey.label) to dictate hands-free, then press it again to finish."
            }
            stopRecording()
        case .none where gesture.awaitingSecondPress:
            DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalkGesture.debounce) { [weak self] in
                guard let self, self.gesture.expire(now: ProcessInfo.processInfo.systemUptime) == .discard else { return }
                self.discardSession()
                if self.tipDue("tap", every: 3600) {
                    self.showNotice("Hold \(self.settings.hotkey.label) while you speak, or double-tap it for hands-free.")
                }
            }
        default: break
        }
    }
    func chordDuringStart() {
        guard gesture.active, !gesture.locked, !sessionSettings.toggleMode,
              phase == .starting || phase == .recording else { return }
        gesture.reset()
        discardSession()
        if tipDue("chord", every: 3600) {
            showNotice("Dictation cancelled: another key was pressed while starting. Hold only \(settings.hotkey.label) to dictate.")
        }
    }
    /// Drops an accidental session without restarting capture, so the next press starts immediately.
    func discardSession() {
        guard let id = machine.id, [.starting, .recording].contains(phase) else { return }
        machine.cancel(); target = nil; level = 0; silentInput = false
        _ = sendCapture(["op": "cancel", "id": id])
        message = "Ready. Recognition stays on this Mac."
        publish()
    }
    func tipDue(_ key: String, every interval: TimeInterval) -> Bool {
        let defaults = UserDefaults.standard, now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: "tip." + key) >= interval else { return false }
        defaults.set(now, forKey: "tip." + key)
        return true
    }
    /// The target is read after capture starts: Accessibility queries can take hundreds of milliseconds,
    /// and the microphone should already be warming up meanwhile.
    func begin(target: @autoclosure () -> TargetSnapshot?) {
        startAttempts += 1
        if phase == .failed {
            // Keep prior recovery files; a fresh recording gets a new session UUID.
            machine.cancel()
            publish()
        }
        guard phase == .idle else { showNotice("Still processing your last dictation. Press Esc to cancel it."); return }
        let evicted = makeRecoveryRoom()
        guard !secureInput, !sleeping else {
            let owner = NativePermissions.secureInputOwner().map { " (\($0))" } ?? ""
            showNotice("Secure Keyboard Entry\(owner) or the lock screen is blocking dictation."); return
        }
        let free = (try? OratorPaths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free > 200_000_000 else {
            showNotice("Your disk is almost full. Free up some space so recordings can be saved safely."); return
        }
        guard microphone else {
            if captureMicrophoneStatus == "notDetermined" {
                requestMicrophone()
                showNotice("Allow microphone access for the capture service, then press Fn again.")
            } else {
                showNotice("Microphone permission is required. Open Settings from the menu-bar icon.")
            }
            return
        }
        guard modelReady && captureReady else {
            showNotice("Local services are not ready. Check Settings from the menu-bar icon."); return
        }
        if evicted { showNotice("Deleted the oldest unrecovered recording to make room.") } else { dismissNotice() }
        let id = UUID().uuidString
        guard machine.begin(id) else { return }
        acceptedStarts += 1
        captureBeganAt = ProcessInfo.processInfo.systemUptime
        self.target = nil
        sessionSettings = settings
        if captureDiagnostic == "running" {
            diagnosticSessionID = id
            sessionSettings.neverStore = true
            sessionSettings.sounds = false
            sessionSettings.toggleMode = false
        }
        phaseStarted = ProcessInfo.processInfo.systemUptime; lastEvent = phaseStarted
        seconds = 0; level = 0; silentInput = false; lowSignal = false; quietSince = nil; micLive = false
        lidBlocksMicrophone = false; inputTransport = ""
        editWatch?.invalidate(); editWatch = nil
        expireUndo()
        message = "Opening microphone…"
        publish()
        guard sendCapture(["op": "start", "id": id, "device": sessionSettings.microphoneUID,
                            "maxSeconds": sessionSettings.maxSeconds, "neverStore": sessionSettings.neverStore]) else {
            fail("Cannot start capture service."); return
        }
        let snapshot = target()
        if machine.id == id { self.target = snapshot }
    }
    /// Real audio is flowing: now it's true to say "Listening".
    func goLive(_ id: String) {
        guard machine.id == id, phase == .recording, !micLive else { return }
        micLive = true; message = "Listening"
        if sessionSettings.sounds { Cues.playStart() }
        if sessionSettings.muteWhileDictating || sessionSettings.pauseMediaWhileDictating {
            // Let the start sound finish before silencing other audio.
            let pause = sessionSettings.pauseMediaWhileDictating
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.phase == .recording, self.machine.id == id else { return }
                if pause { self.mediaPause.pause() } else { self.outputMute.mute() }
            }
        }
        onChange?()
    }
    func stopRecording() {
        guard let id = machine.id else { return }
        if phase == .starting { earlyReleases += 1 }
        guard [.starting, .recording].contains(phase),
              machine.advance(id, to: .stopping) else { return }
        phaseStarted = ProcessInfo.processInfo.systemUptime
        message = "Finishing recording…"; publish()
        if !sendCapture(["op": "stop", "id": id]) { fail("Capture disconnected while stopping.") }
    }
    func captureMessage(_ object: [String: Any]) {
        let event = object["event"] as? String
        if event == "ready" {
            captureReady = true
            capture.send(["op": "permissions"])
            if pendingMicrophoneRequest {
                pendingMicrophoneRequest = false
                capture.send(["op": "requestMicrophone"])
            }
            return
        }
        if event == "permissions" {
            captureMicrophoneStatus = object["microphone"] as? String ?? "unknown"
            microphone = captureMicrophoneStatus == "authorized"
            writeDiagnostics()
            return
        }
        if let id = object["id"] as? String, id == undoSession?.id, ["stopped", "interrupted", "cancelled"].contains(event) {
            let usable = event != "cancelled" && (object["samples"] as? Int ?? 0) >= 160 && object["silent"] as? Bool != true
            if usable { undoAvailable = true; onChange?() } else { expireUndo() }
            return
        }
        guard let id = object["id"] as? String, machine.id == id else { return }
        lastEvent = ProcessInfo.processInfo.systemUptime
        switch event {
        case "recording":
            captureStartLatency = max(0, lastEvent - captureBeganAt)
            guard machine.advance(id, to: .recording) else { return }
            phaseStarted = lastEvent; message = "Starting"
            // Never leave the user waiting on a cue: a muted mic gets its own hint instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.machine.id == id, self.phase == .recording, !self.micLive else { return }
                self.goLive(id)
            }
            inputTransport = object["transport"] as? String ?? ""
            lidBlocksMicrophone = inputTransport == "builtIn" && object["clamshell"] as? Bool == true
            publish()
        case "live":
            micWarmup = object["warmup"] as? Double ?? 0
            captureStartLatency = max(0, lastEvent - captureBeganAt)
            goLive(id)
        case "level":
            level = object["level"] as? Double ?? 0
            seconds = object["seconds"] as? Double ?? 0
            // About -70 dBFS for 5 s: a disconnected, muted or turned-down input rather than a quiet room.
            if level < 0.0003 {
                quietSince = quietSince ?? lastEvent
                lowSignal = lastEvent - (quietSince ?? lastEvent) >= 5
            } else { quietSince = nil; lowSignal = false }
        case "silent":
            silentInput = object["silent"] as? Bool ?? false
        case "stopped":
            if id == diagnosticSessionID {
                finishCaptureDiagnostic(samples: object["samples"] as? Int ?? 0, error: nil)
                return
            }
            if phase == .recording && object["reason"] as? String == "limit" {
                _ = machine.advance(id, to: .stopping)
                publish()
            }
            guard phase == .stopping else { return }
            if sessionSettings.sounds { Cues.playStop() }
            guard (object["samples"] as? Int ?? 0) >= 160 else {
                OratorPaths.remove(id); machine.cancel(); publish()
                showNotice("No audio captured. Hold \(settings.hotkey.label) until Listening appears, or use press-to-toggle mode.")
                return
            }
            if object["silent"] as? Bool == true {
                // Exact digital silence is a muted or broken input; there is nothing worth recovering.
                OratorPaths.remove(id); machine.cancel(); silentInput = false; publish()
                showNotice(lidBlocksMicrophone ?
                    "The lid is closed, so the built-in mic can't hear you. Pick another microphone in Settings." :
                    "The microphone sent only silence. Check that it isn't muted, or pick another input in Settings.",
                    action: ("Settings", { [weak self] in self?.showWindow?() }))
                return
            }
            if object["poorQuality"] as? Bool == true && tipDue("quality", every: 86400) {
                pendingTip = "We didn't hear you clearly: the mic level is low or noisy. Move closer or pick another microphone."
            } else if inputTransport == "bluetooth" && tipDue("bluetooth", every: 7 * 86400) {
                pendingTip = "Bluetooth mics add delay and lower accuracy. The built-in or a wired mic works best."
            }
            transcribe(id)
        case "interrupted", "error":
            if id == diagnosticSessionID {
                finishCaptureDiagnostic(samples: object["samples"] as? Int ?? 0,
                                        error: object["message"] as? String ?? "Capture failed")
                return
            }
            fail(object["message"] as? String ?? "Microphone interrupted.")
        default: break
        }
    }
    func transcribe(_ id: String) {
        guard modelReady, machine.advance(id, to: .transcribing) else {
            fail("Local model is not ready; audio retained."); return
        }
        phaseStarted = ProcessInfo.processInfo.systemUptime; lastEvent = phaseStarted
        message = "Transcribing locally…"; publish()
        guard worker.send(["op": "transcribe", "id": id, "path": OratorPaths.pcm(id).path]) else {
            fail("Cannot reach local model."); return
        }
    }
    func workerMessage(_ object: [String: Any]) {
        let event = object["event"] as? String
        if event == "ready" {
            modelReady = true
            if phase == .idle { message = "Ready. Recognition stays on this Mac." }
            // The smaller model is running, so the old full-precision copy is no longer needed.
            if settings.modelPath.isEmpty, FileManager.default.fileExists(atPath: OratorPaths.legacyModel.path) {
                try? FileManager.default.removeItem(at: OratorPaths.legacyModel)
            }
            return
        }
        if event == "fatal" {
            modelReady = false; worker.stop()
            if busy { fail("Local model failed to load. Audio retained.") }
            else { message = object["message"] as? String ?? "Model loading failed." }
            return
        }
        guard let id = object["id"] as? String, machine.id == id, phase == .transcribing else { return }
        lastEvent = ProcessInfo.processInfo.systemUptime
        if event == "progress" {
            let progress = Int((object["fraction"] as? Double ?? 0) * 100)
            message = "Transcribing locally… \(progress)%"; return
        }
        if event == "error" { fail("Transcription failed. Use Retry transcription."); return }
        guard event == "result", let raw = object["text"] as? String else { return }
        let text = sessionSettings.transform(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("No speech recognized. You can retry or discard the recording."); return
        }
        lastText = text
        lastTextSessionID = id
        guard machine.advance(id, to: .inserting) else { return }
        publish()
        if sessionSettings.autoInsert {
            message = "Inserting…"
            insertion.insert(text, target: target, preserve: sessionSettings.preserveClipboard,
                             smart: sessionSettings.smartFormatting,
                             unverified: sessionSettings.pasteWithoutCursor) { [weak self] result, delivered in
                self?.complete(id, result, delivered: delivered)
            }
        } else {
            copyLast()
            complete(id, "Transcript copied. Paste it where you want.", delivered: true)
        }
    }
    func complete(_ id: String, _ result: String, delivered: Bool) {
        guard machine.id == id, machine.phase == .inserting else { return }
        guard machine.advance(id, to: delivered ? .idle : .failed) else { return }
        if delivered || sessionSettings.neverStore { OratorPaths.remove(id) }
        target = nil; level = 0; message = result
        if !delivered { lastFailureReason = result; annotateFailure(id, result); showNotice(result) }
        else if let tip = pendingTip { message = tip }
        pendingTip = nil
        if delivered, let verified = insertion.lastVerified { watchEdits(verified) }
        refreshRecovery(); publish()
    }
    private func annotateFailure(_ id: String, _ reason: String) {
        guard servicesEnabled, UUID(uuidString: id) != nil,
              let data = try? Data(contentsOf: OratorPaths.manifest(id)),
              var entry = try? JSONDecoder().decode(Recovery.self, from: data) else { return }
        entry.failureReason = reason
        if let updated = try? JSONEncoder().encode(entry) {
            try? updated.write(to: OratorPaths.manifest(id), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OratorPaths.manifest(id).path)
        }
    }
    func showNotice(_ text: String, duration: TimeInterval = 3.5, action: (label: String, run: () -> Void)? = nil) {
        message = text
        notice = text
        noticeAction = action
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in self?.dismissNotice() }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
        onChange?()
    }
    func dismissNotice() {
        noticeTimer?.invalidate(); noticeTimer = nil
        notice = nil; noticeAction = nil
        onChange?()
    }
    func fail(_ reason: String) {
        if [.starting, .recording, .stopping].contains(phase) {
            let failedID = machine.id
            let removeAudio = sessionSettings.neverStore
            capture.stop { [weak self] in
                if removeAudio, let failedID { OratorPaths.remove(failedID); self?.refreshRecovery() }
                else if let failedID { self?.annotateFailure(failedID, reason) }
            }
            captureReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.shuttingDown, !self.sleeping, !self.capture.running else { return }
                self.startCapture()
            }
        }
        if let id = machine.id {
            _ = machine.advance(id, to: .failed)
            if sessionSettings.neverStore { OratorPaths.remove(id) }
            else { annotateFailure(id, reason) }
        }
        insertion.cancel()
        target = nil; level = 0; message = reason
        lastFailureReason = reason
        showNotice(reason)
        refreshRecovery(); publish()
    }
    func cancel() {
        let previous = phase
        let id = machine.id
        machine.cancel(); publish()
        insertion.cancel()
        if previous == .starting || previous == .recording || previous == .stopping {
            if let id { capture.send(["op": "cancel", "id": id]) }
            capture.stop { [weak self] in
                if let id { OratorPaths.remove(id) }
                self?.refreshRecovery()
                self?.startCapture()
            }
            captureReady = false
        }
        if previous == .transcribing {
            worker.stop(); modelReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.startWorker() }
        }
        if ![.starting, .recording, .stopping].contains(previous), let id { OratorPaths.remove(id) }
        target = nil; level = 0; message = "Cancelled. Nothing else will be inserted."
        refreshRecovery(); publish()
    }
    /// Escape while recording keeps the audio for a few seconds so an accidental cancel can be undone.
    func cancelWithUndo() {
        guard phase == .recording, let id = machine.id else { cancel(); return }
        expireUndo()
        undoSession = (id, target, sessionSettings)
        machine.cancel(); target = nil; level = 0; silentInput = false; lowSignal = false
        _ = sendCapture(["op": "stop", "id": id])
        publish()
        showNotice("Dictation cancelled.", duration: 4)
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.expireUndo() }
        RunLoop.main.add(timer, forMode: .common)
        undoTimer = timer
    }
    func expireUndo() {
        undoTimer?.invalidate(); undoTimer = nil
        guard let session = undoSession else { return }
        undoSession = nil; undoAvailable = false
        OratorPaths.remove(session.id); refreshRecovery(); onChange?()
    }
    func undoCancel() {
        guard undoAvailable, let session = undoSession, !busy else { return }
        guard modelReady else { showNotice("The local model is still loading. Try Undo again in a moment."); return }
        undoTimer?.invalidate(); undoTimer = nil; undoSession = nil; undoAvailable = false
        dismissNotice()
        machine.cancel()
        _ = machine.begin(session.id); _ = machine.advance(session.id, to: .failed)
        sessionSettings = session.settings; target = session.target
        transcribe(session.id)
    }
    /// Never block a new dictation on old failures: drop recordings too short to hold speech, then the
    /// oldest. Returns whether a usable recording had to be deleted.
    @discardableResult func makeRecoveryRoom() -> Bool {
        refreshRecovery()
        guard recoveries.count >= Self.maxPendingRecoveries else { return false }
        var entries = recoveries.sorted { $0.created > $1.created }
        for entry in entries where entry.samples < 8000 { OratorPaths.remove(entry.id) }
        entries.removeAll { $0.samples < 8000 }
        var evicted = false
        while entries.count >= Self.maxPendingRecoveries, let oldest = entries.popLast() {
            OratorPaths.remove(oldest.id); evicted = true
        }
        recoveries = entries
        refreshRecovery()
        return evicted
    }
    /// Watches the field for a minute after a verified insertion; corrected words become a suggestion.
    func watchEdits(_ verified: Insertion.Verified) {
        editWatch?.invalidate()
        let began = ProcessInfo.processInfo.systemUptime
        var suggestions: [Replacement] = []
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let focused = TargetSnapshot.capture()
            let present = focused.map { $0.pid == verified.pid && CFEqual($0.element, verified.element) } ?? false
            if present, let value = TargetSnapshot.attribute(verified.element, kAXValueAttribute) as? String,
               let region = EditLearning.editedRegion(prefix: verified.prefix, suffix: verified.suffix, current: value) {
                suggestions = EditLearning.corrections(inserted: verified.text, edited: region).filter { candidate in
                    !self.settings.replacements.contains { $0.from == candidate.from }
                }
            }
            guard !present || self.busy || ProcessInfo.processInfo.systemUptime - began > 60 else { return }
            timer.invalidate(); self.editWatch = nil
            guard !suggestions.isEmpty, !self.busy else { return }
            self.suggest(suggestions)
        }
        RunLoop.main.add(timer, forMode: .common)
        editWatch = timer
    }
    func suggest(_ suggestions: [Replacement]) {
        let list = suggestions.map { "“\($0.from)” → “\($0.to)”" }.joined(separator: ", ")
        showNotice("Add to vocabulary: \(list)?", duration: 6, action: ("Add", { [weak self] in
            guard let self else { return }
            let fresh = suggestions.filter { candidate in !self.settings.replacements.contains { $0.from == candidate.from } }
            self.settings.replacements.append(contentsOf: fresh.prefix(max(0, 200 - self.settings.replacements.count)))
            self.message = "Added to vocabulary."
        }))
    }
    func refreshRecovery() {
        guard servicesEnabled else { return }
        recoveries = OratorPaths.recoveries()
    }
    func retry(_ recovery: Recovery? = nil) {
        guard !busy, modelReady else { message = "Wait for local services to be ready."; return }
        refreshRecovery()
        let id = recovery?.id ?? machine.id ?? recoveries.first?.id
        guard let id, FileManager.default.fileExists(atPath: OratorPaths.pcm(id).path) else {
            message = "No recording is available to retry."; return
        }
        if let recovery, Date().timeIntervalSince(recovery.created) > 86400 {
            OratorPaths.remove(id); refreshRecovery()
            message = "This recording expired and was deleted."; return
        }
        machine.cancel()
        _ = machine.begin(id); _ = machine.advance(id, to: .failed)
        sessionSettings = settings
        // A recovered recording must not insert at an old or newly focused target automatically.
        sessionSettings.autoInsert = false; target = nil
        transcribe(id)
    }
    func discard() {
        guard !busy else { return }
        if let id = machine.id { OratorPaths.remove(id) }
        for recovery in recoveries { OratorPaths.remove(recovery.id) }
        machine.cancel(); refreshRecovery(); publish()
        message = "Pending audio discarded."
    }
    func copyLast() {
        guard !lastText.isEmpty else { return }
        if insertion.busy { insertion.cancel() }
        let board = NSPasteboard.general; board.clearContents()
        guard board.setString(lastText, forType: .string) else {
            message = "Could not copy transcript. It remains available here."; return
        }
        if phase == .failed, machine.id == lastTextSessionID, let id = machine.id {
            OratorPaths.remove(id); machine.cancel(); refreshRecovery(); publish()
            message = "Transcript copied. Pending audio deleted."
        }
    }
    func pasteLast() {
        guard !busy, !lastText.isEmpty else { return }
        insertion.insert(lastText, target: menuTarget ?? TargetSnapshot.capture(),
                         preserve: settings.preserveClipboard) { [weak self] result, _ in self?.message = result }
    }
    func restart() {
        guard !busy else { message = "Finish or cancel dictation before restarting services."; return }
        capture.resetFailures(); worker.resetFailures()
        keys.stop()
        startCapture(); startWorker()
        message = "Restarting local services…"
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { message = "Login setting could not be changed. Check System Settings → Login Items." }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    @objc func suspend() {
        sleeping = true; keys.stop()
        if busy {
            capture.stop(); worker.stop(); captureReady = false; modelReady = false
            fail("Stopped for sleep or lock. Recover captured audio explicitly.")
        }
        configureKeys()
    }
    @objc func resume() {
        sleeping = false; keys.didWake()
        phaseStarted = ProcessInfo.processInfo.systemUptime; lastEvent = phaseStarted
        refreshPermissions(); refreshDevices()
        if !capture.running { startCapture() }
        if !worker.running { startWorker() }
    }
    func tick() {
        defer { writeDiagnostics() }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastTick; lastTick = now
        refreshPermissions(); keys.reconcile()
        advanceCaptureDiagnostic(now)
        if now - lastRecoverySweep > 60 && !busy {
            lastRecoverySweep = now; refreshRecovery(); cleanOrphans(); refreshDevices()
        }
        if busy && secureInput {
            worker.stop(); modelReady = false
            fail("Secure Input became active. Recording stopped; recover audio explicitly.")
            return
        }
        if [.starting, .recording].contains(phase) && !microphone {
            fail("Microphone permission was revoked. Captured audio is available to recover.")
            return
        }
        if gap > 5 {
            phaseStarted = now; lastEvent = now
            if busy { capture.stop(); worker.stop(); captureReady = false; modelReady = false
                fail("System paused during dictation. Recover captured audio explicitly.") }
            return
        }
        if phase == .starting && now - phaseStarted > 3 && message == "Opening microphone…" {
            message = "Still waiting for the microphone. Bluetooth inputs can take a few seconds."
        }
        if phase == .starting && now - phaseStarted > 12 {
            capture.stop(); captureReady = false; fail("Microphone startup timed out. Restart services and retry.")
        } else if phase == .recording && now - lastEvent > 8 {
            capture.stop(); captureReady = false; fail("Audio stopped arriving. Partial recording retained.")
        } else if phase == .stopping && now - phaseStarted > 5 {
            capture.stop(); captureReady = false; fail("Microphone drain timed out. Partial recording retained.")
        } else if phase == .transcribing && (now - lastEvent > 90 || now - phaseStarted > 600) {
            worker.stop(); modelReady = false; fail("Local transcription timed out. Audio retained for retry.")
        }
        if !modelReady && worker.running && now - workerStarted > 180 {
            worker.stop(); message = "Model startup timed out. Check Settings and restart services."
        }
        if !captureReady && capture.running && now - captureStarted > 15 {
            capture.stop(); message = "Capture helper did not become ready."
        }
        onChange?()
    }
    func shutdown(completion: @escaping () -> Void = {}) {
        shuttingDown = true
        noticeTimer?.invalidate()
        watchdog?.invalidate(); keys.stop(); insertion.cancel()
        let id = machine.id
        let removeAudio = sessionSettings.neverStore
        capture.stop {
            if removeAudio, let id { OratorPaths.remove(id) }
            completion()
        }
        worker.stop()
    }
    func writeDiagnostics() {
        guard servicesEnabled else { return }
        let snapshot: [String: Any] = [
            "phase": phase.rawValue, "modelReady": modelReady, "captureReady": captureReady,
            "shortcutReady": shortcutReady, "microphonePermission": microphone,
            "captureMicrophoneStatus": captureMicrophoneStatus,
            "appMicrophoneStatus": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "accessibilityPermission": accessibility, "secureInput": secureInput,
            "appleFnKey": fnKeyAvailable, "handsFree": handsFree, "undoAvailable": undoAvailable,
            "inputMonitoringPermission": permissionEvidence.inputMonitoringAllowed,
            "eventPostingPermission": permissionEvidence.eventPostingAllowed,
            "accessibilityProbe": permissionEvidence.accessibilityProbe.rawValue,
            "permissionRequestPending": permissionRequest.pending?.rawValue ?? "",
            "permissionRequestTimedOut": permissionRequest.timedOut?.rawValue ?? "",
            "bundlePath": Bundle.main.bundlePath,
            "stableSigning": Bundle.main.object(forInfoDictionaryKey: "OratorStableSigning") as? Bool ?? false,
            "lastFailureReason": lastFailureReason ?? "",
            "keyboard": keys.diagnostics(),
            "startAttempts": startAttempts, "acceptedStarts": acceptedStarts,
            "releaseBeforeAudio": earlyReleases, "captureStartLatency": captureStartLatency, "micWarmup": micWarmup,
            "captureDiagnostic": captureDiagnostic, "diagnosticSamples": diagnosticSamples,
            "diagnosticDetail": diagnosticDetail, "textInsertionDiagnostic": textInsertionDiagnostic,
            "pendingRecoveryCount": recoveries.count, "updatedAt": Date().timeIntervalSince1970,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        ]
        let path = OratorPaths.support.appendingPathComponent("diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
    func requestCaptureDiagnostic() {
        guard !busy else { return }
        captureDiagnostic = "waiting"
        diagnosticStartedAt = ProcessInfo.processInfo.systemUptime
        diagnosticSamples = 0
        diagnosticDetail = ""
    }
    func requestTextInsertionDiagnostic() {
        guard !busy else { return }
        let token = UUID()
        textDiagnosticToken = token
        textInsertionDiagnostic = "waiting"
        recordingShortcut = true
        do {
            let folder = OratorPaths.support.appendingPathComponent("Verification", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("Orator Verification \(token.uuidString).txt")
            try Data().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self, self.textDiagnosticToken == token, !self.shuttingDown else { return }
                    if error != nil { self.endTextDiagnostic(false, "Could not open the test editor"); return }
                    self.insertIntoTestDocument(token: token, attempts: 30)
                }
            }
        } catch { endTextDiagnostic(false, "Could not create the test document") }
    }
    private func insertIntoTestDocument(token: UUID, attempts: Int) {
        guard textDiagnosticToken == token, !shuttingDown else { return }
        var ownsWindow = false
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.TextEdit" {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            if let raw = TargetSnapshot.attribute(application, kAXFocusedWindowAttribute),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(raw, to: AXUIElement.self)
                let title = TargetSnapshot.attribute(window, kAXTitleAttribute) as? String ?? ""
                ownsWindow = title.contains(token.uuidString)
            }
        }
        guard ownsWindow, let target = TargetSnapshot.capture(), target.role == "AXTextArea",
              target.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
            guard attempts > 0 else { endTextDiagnostic(false, "The owned empty test document did not become accessible"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.insertIntoTestDocument(token: token, attempts: attempts - 1)
            }
            return
        }
        textInsertionDiagnostic = "inserting"
        let phrase = "Orator verification: text insertion stays on this Mac."
        insertion.insert(phrase, target: target, preserve: true) { [weak self] result, delivered in
            guard let self, self.textDiagnosticToken == token, !self.shuttingDown else { return }
            let value = TargetSnapshot.attribute(target.element, kAXValueAttribute) as? String
            self.endTextDiagnostic(delivered && value?.trimmingCharacters(in: .whitespacesAndNewlines) == phrase,
                                   delivered ? "Owned TextEdit document read back after insertion" : result)
        }
    }
    private func endTextDiagnostic(_ success: Bool, _ detail: String) {
        textInsertionDiagnostic = success ? "passed" : "failed"
        diagnosticDetail = detail
        recordingShortcut = false
        message = detail
        writeDiagnostics()
    }
    private func advanceCaptureDiagnostic(_ now: TimeInterval) {
        if captureDiagnostic == "waiting" {
            if now - diagnosticStartedAt > 30 {
                captureDiagnostic = "failed"; diagnosticDetail = "Services did not become ready"
                return
            }
            if captureReady && ["denied", "restricted", "notDetermined"].contains(captureMicrophoneStatus) {
                captureDiagnostic = "permissionRequired"
                diagnosticDetail = "Capture process microphone status: " + captureMicrophoneStatus
                return
            }
            guard modelReady, captureReady, microphone, shortcutReady else { return }
            guard settings.hotkey.isFnOnly else {
                captureDiagnostic = "failed"; diagnosticDetail = "Diagnostic requires the configured Fn shortcut"
                return
            }
            captureDiagnostic = "running"
            diagnosticStartedAt = now
            postDiagnosticFn(down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.captureDiagnostic == "running" else { return }
                self.postDiagnosticFn(down: false)
            }
        } else if captureDiagnostic == "running" && now - diagnosticStartedAt > 12 {
            postDiagnosticFn(down: false)
            finishCaptureDiagnostic(samples: 0, error: "No complete Fn capture cycle received")
        }
    }
    private func postDiagnosticFn(down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.setIntegerValueField(.eventSourceUserData, value: 0x4C464454)
        event.post(tap: .cghidEventTap)
    }
    private func finishCaptureDiagnostic(samples: Int, error: String?) {
        let id = diagnosticSessionID
        diagnosticSessionID = nil
        diagnosticSamples = samples
        captureDiagnostic = error == nil && samples >= 160 ? "passed" : "failed"
        diagnosticDetail = error ?? (samples >= 160 ? "Fn event, native capture and drain completed; no speech transcribed" :
                                     "No usable samples captured")
        machine.cancel(); publish()
        if error != nil {
            captureReady = false
            capture.stop { [weak self] in
                if let id { OratorPaths.remove(id) }
                self?.startCapture()
            }
        } else if let id { OratorPaths.remove(id) }
        refreshRecovery()
        message = diagnosticDetail
    }
}
