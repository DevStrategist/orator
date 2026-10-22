import Foundation

public enum CaptureConfigurationAction: Equatable {
    case keepRecording, restartOnce, interrupt
}

public enum CapturePolicy {
    /// Transient HAL/driver start failures usually clear quickly; permission failures are never retried.
    public static let startRetryDelays: [Double] = [0.25, 0.75]
    /// Exact-zero PCM for this long means a muted or broken input, not quiet speech.
    public static let silentSamples = 16000
    /// A powered microphone never yields this many consecutive exact zeros; warm-up does.
    public static let warmupZeroRun = 32
    /// Continuous real audio needed before telling the user to speak (100 ms).
    public static let liveSamples = 1600
    public static let maxConfigurationRestarts = 3
    public static func retryStart(shouldStop: () -> Bool,
                                  wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                  attempt: () throws -> Void) throws -> Bool {
        var delays = startRetryDelays[...]
        while !shouldStop() {
            do { try attempt(); return true }
            catch {
                if shouldStop() { return false }
                guard let delay = delays.popFirst() else { throw error }
                wait(delay)
            }
        }
        return false
    }
    public static func needsAudioRecovery(callbackAge: Double, startupAge: Double,
                                          heardSignal: Bool, silentStartRetried: Bool) -> Bool {
        callbackAge >= 5 || (!heardSignal && !silentStartRetried && startupAge >= 6)
    }
    public static func configurationChange(running: Bool, formatUnchanged: Bool,
                                           deviceChanged: Bool, restarts: Int) -> CaptureConfigurationAction {
        guard !deviceChanged else { return .interrupt }
        if running && formatUnchanged { return .keepRecording }
        return restarts < maxConfigurationRestarts ? .restartOnce : .interrupt
    }
}
