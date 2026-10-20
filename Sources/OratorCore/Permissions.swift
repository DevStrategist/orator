import Foundation

public enum PermissionKind: String {
    case accessibility, inputMonitoring
}

public enum AccessibilityProbe: String {
    case working, denied, unavailable
}

public struct PermissionEvidence: Equatable {
    public var accessibilityTrusted: Bool
    public var accessibilityProbe: AccessibilityProbe
    public var inputMonitoringAllowed: Bool
    public var eventPostingAllowed: Bool
    public init(accessibilityTrusted: Bool = false, accessibilityProbe: AccessibilityProbe = .unavailable,
                inputMonitoringAllowed: Bool = false, eventPostingAllowed: Bool = false) {
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityProbe = accessibilityProbe
        self.inputMonitoringAllowed = inputMonitoringAllowed
        self.eventPostingAllowed = eventPostingAllowed
    }
    public func granted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return accessibilityTrusted
        case .inputMonitoring: return inputMonitoringAllowed
        }
    }
    public var accessibilityOperational: Bool {
        accessibilityTrusted && accessibilityProbe != .denied
    }
    /// An active tap needs Accessibility; Input Monitoring alone still allows a listen-only tap.
    public var shortcutTapMode: TapMode {
        if accessibilityOperational { return .active }
        return inputMonitoringAllowed ? .listenOnly : .unavailable
    }
}

public struct PermissionRequest {
    public private(set) var pending: PermissionKind?
    public private(set) var timedOut: PermissionKind?
    private var requestedAt: TimeInterval = 0
    public init() {}
    public mutating func begin(_ kind: PermissionKind, now: TimeInterval) {
        pending = kind; timedOut = nil; requestedAt = now
    }
    public mutating func refresh(_ evidence: PermissionEvidence, now: TimeInterval) {
        if let pending {
            if evidence.granted(pending) {
                self.pending = nil; timedOut = nil
            } else if now - requestedAt >= 10 {
                self.pending = nil; timedOut = pending
            }
        }
        if let timedOut, evidence.granted(timedOut) { self.timedOut = nil }
    }
}
