import AppKit
import ApplicationServices
import Carbon
import OratorCore

enum NativePermissions {
    static func sessionIsActive(_ session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any]) -> Bool? {
        guard let session, let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else { return nil }
        return onConsole && session[kCGSessionLoginDoneKey as String] as? Bool == true &&
            session["CGSSessionScreenIsLocked"] as? Bool != true
    }
    static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
    static func sample() -> PermissionEvidence {
        let trusted = accessibilityTrusted()
        var probe: AccessibilityProbe = .unavailable
        if trusted, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            // Read only the application role, never window titles or document text.
            let application = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &value)
            if result == .success { probe = .working }
            else if result == .apiDisabled { probe = .denied }
        }
        return PermissionEvidence(accessibilityTrusted: trusted, accessibilityProbe: probe,
                                  inputMonitoringAllowed: CGPreflightListenEventAccess(),
                                  eventPostingAllowed: CGPreflightPostEventAccess())
    }
    /// Name of the app holding Secure Keyboard Entry, read from the window server session.
    static func secureInputOwner() -> String? {
        guard IsSecureEventInputEnabled(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }
}
