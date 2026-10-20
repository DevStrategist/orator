import Foundation

public enum CaptureConfigurationAction: Equatable {
    case keepRecording, restartOnce, interrupt
}

public enum CapturePolicy {
    /// Transient HAL/driver start failures usually clear quickly; permission failures are never retried.
    public static let startRetryDelays: [Double] = [0.25, 0.75]
    /// Exact-zero PCM for this long means a muted or broken input, not quiet speech.
    public static let silentSamples = 16000
    public static func configurationChange(running: Bool, formatUnchanged: Bool,
                                           deviceChanged: Bool, restarts: Int) -> CaptureConfigurationAction {
        guard !deviceChanged, formatUnchanged else { return .interrupt }
        if running { return .keepRecording }
        return restarts < 1 ? .restartOnce : .interrupt
    }
}
