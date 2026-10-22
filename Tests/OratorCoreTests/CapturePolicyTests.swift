import XCTest
@testable import OratorCore

final class CapturePolicyTests: XCTestCase {
    func testBenignConfigurationNotificationDoesNotAbortCapture() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 0), .keepRecording)
    }
    func testStoppedGraphAllowsBoundedBluetoothRenegotiation() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: false, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 0), .restartOnce)
        XCTAssertEqual(CapturePolicy.configurationChange(running: false, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 1), .restartOnce)
        XCTAssertEqual(CapturePolicy.configurationChange(running: false, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 3), .interrupt)
    }
    func testRealDeviceChangeStopsSafely() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: true,
                                                        deviceChanged: true, restarts: 0), .interrupt)
    }
    func testSameMicrophoneFormatChangeRebuildsCapture() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: false,
                                                        deviceChanged: false, restarts: 0), .restartOnce)
    }
    func testTransientCaptureFailureRetriesUntilAudioStarts() throws {
        var attempts = 0
        var waits: [Double] = []
        let started = try CapturePolicy.retryStart(shouldStop: { false }, wait: { waits.append($0) }) {
            attempts += 1
            if attempts < 3 { throw NSError(domain: "driver", code: -1) }
        }
        XCTAssertTrue(started)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, [0.25, 0.75])
    }
    func testCaptureRetriesStopAfterPersistentDriverFailure() {
        var attempts = 0
        XCTAssertThrowsError(try CapturePolicy.retryStart(shouldStop: { false }, wait: { _ in }) {
            attempts += 1
            throw NSError(domain: "driver", code: -10868)
        }) { XCTAssertEqual(($0 as NSError).code, -10868) }
        XCTAssertEqual(attempts, 3)
    }
    func testCancellationDuringBackoffCannotOpenAnotherMicrophone() throws {
        var cancelled = false
        var attempts = 0
        let started = try CapturePolicy.retryStart(shouldStop: { cancelled }, wait: { _ in cancelled = true }) {
            attempts += 1
            throw NSError(domain: "driver", code: -1)
        }
        XCTAssertFalse(started)
        XCTAssertEqual(attempts, 1)
    }
    func testAudioHealthRepairsMissingCallbacksAndSilentStartupOnly() {
        XCTAssertTrue(CapturePolicy.needsAudioRecovery(callbackAge: 5, startupAge: 6,
            heardSignal: true, silentStartRetried: false))
        XCTAssertTrue(CapturePolicy.needsAudioRecovery(callbackAge: 0, startupAge: 6,
            heardSignal: false, silentStartRetried: false))
        XCTAssertFalse(CapturePolicy.needsAudioRecovery(callbackAge: 0, startupAge: 6,
            heardSignal: false, silentStartRetried: true))
        XCTAssertFalse(CapturePolicy.needsAudioRecovery(callbackAge: 0, startupAge: 60,
            heardSignal: true, silentStartRetried: false))
        XCTAssertFalse(CapturePolicy.needsAudioRecovery(callbackAge: 0, startupAge: 2,
            heardSignal: false, silentStartRetried: false))
    }
    func testOldRecoveryMetadataRemainsDecodable() throws {
        let original = Recovery(id: UUID().uuidString)
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "failureReason")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Recovery.self, from: legacy)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.failureReason)
    }
}
