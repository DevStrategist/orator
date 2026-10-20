import XCTest
@testable import OratorCore

final class CapturePolicyTests: XCTestCase {
    func testBenignConfigurationNotificationDoesNotAbortCapture() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 0), .keepRecording)
    }
    func testStoppedGraphGetsOnlyOneRecoveryAttempt() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: false, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 0), .restartOnce)
        XCTAssertEqual(CapturePolicy.configurationChange(running: false, formatUnchanged: true,
                                                        deviceChanged: false, restarts: 1), .interrupt)
    }
    func testRealDeviceOrFormatChangeStopsSafely() {
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: true,
                                                        deviceChanged: true, restarts: 0), .interrupt)
        XCTAssertEqual(CapturePolicy.configurationChange(running: true, formatUnchanged: false,
                                                        deviceChanged: false, restarts: 0), .interrupt)
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
