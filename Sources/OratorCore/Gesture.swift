import Foundation

public enum GestureAction: Equatable {
    case none, start, stop, lock, discard
}

/// Hold-to-talk gestures: a quick tap is not a dictation, and a quick
/// second press locks the session hands-free until the shortcut is pressed again.
public struct PushToTalkGesture {
    public static let debounce = 0.5
    public private(set) var locked = false
    private var startedAt: Double?
    private var releasedEarlyAt: Double?
    public init() {}

    public var active: Bool { startedAt != nil }
    public var awaitingSecondPress: Bool { releasedEarlyAt != nil }

    public mutating func press(now: Double) -> GestureAction {
        guard let startedAt else {
            self.startedAt = now; locked = false; releasedEarlyAt = nil
            return .start
        }
        if locked {
            let action: GestureAction = now - startedAt < Self.debounce ? .discard : .stop
            reset(); return action
        }
        if releasedEarlyAt != nil, now - startedAt < Self.debounce {
            self.releasedEarlyAt = nil; locked = true
            return .lock
        }
        return .none
    }

    public mutating func release(now: Double) -> GestureAction {
        guard let startedAt, !locked, releasedEarlyAt == nil else { return .none }
        if now - startedAt < Self.debounce { releasedEarlyAt = now; return .none }
        reset()
        return .stop
    }

    /// Called once the debounce after an early release has passed.
    public mutating func expire(now: Double) -> GestureAction {
        guard let releasedEarlyAt, !locked, now - releasedEarlyAt >= Self.debounce - 0.001 else { return .none }
        reset()
        return .discard
    }

    public mutating func reset() { startedAt = nil; releasedEarlyAt = nil; locked = false }
}
