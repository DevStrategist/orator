import XCTest
@testable import OratorCore

final class PermissionTests: XCTestCase {
    func testOpeningSettingsDoesNotGrantAccess() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 100)
        request.refresh(PermissionEvidence(), now: 101)
        XCTAssertEqual(request.pending, .accessibility)
        XCTAssertNil(request.timedOut)
    }
    func testNativeGrantCompletesPendingRequest() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 100)
        request.refresh(PermissionEvidence(accessibilityTrusted: true), now: 101)
        XCTAssertNil(request.pending)
        XCTAssertNil(request.timedOut)
    }
    func testInputMonitoringDoesNotPretendAccessibilityIsGranted() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 100)
        let evidence = PermissionEvidence(inputMonitoringAllowed: true, eventPostingAllowed: true)
        request.refresh(evidence, now: 101)
        XCTAssertEqual(request.pending, .accessibility)
        XCTAssertFalse(evidence.accessibilityOperational)
    }
    func testAccessibilityDoesNotPretendInputMonitoringIsGranted() {
        var request = PermissionRequest()
        request.begin(.inputMonitoring, now: 100)
        request.refresh(PermissionEvidence(accessibilityTrusted: true), now: 101)
        XCTAssertEqual(request.pending, .inputMonitoring)
    }
    func testInputMonitoringGrantCompletesItsOwnRequest() {
        var request = PermissionRequest()
        request.begin(.inputMonitoring, now: 100)
        request.refresh(PermissionEvidence(inputMonitoringAllowed: true), now: 101)
        XCTAssertNil(request.pending)
    }
    func testRequestTimeoutBoundary() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 100)
        request.refresh(PermissionEvidence(), now: 109.99)
        XCTAssertEqual(request.pending, .accessibility)
        request.refresh(PermissionEvidence(), now: 110)
        XCTAssertNil(request.pending)
        XCTAssertEqual(request.timedOut, .accessibility)
    }
    func testLateGrantClearsTimeoutWithoutRestart() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 100)
        request.refresh(PermissionEvidence(), now: 110)
        request.refresh(PermissionEvidence(accessibilityTrusted: true), now: 120)
        XCTAssertNil(request.pending)
        XCTAssertNil(request.timedOut)
    }
    func testRetriedRequestGetsFreshDeadline() {
        var request = PermissionRequest()
        request.begin(.accessibility, now: 0)
        request.refresh(PermissionEvidence(), now: 10)
        request.begin(.accessibility, now: 20)
        request.refresh(PermissionEvidence(), now: 21)
        XCTAssertEqual(request.pending, .accessibility)
        XCTAssertNil(request.timedOut)
    }
    func testDefaultShortcutDoesNotRequireOptionalListenPermission() {
        let evidence = PermissionEvidence(accessibilityTrusted: true, accessibilityProbe: .working)
        XCTAssertTrue(evidence.accessibilityOperational)
        XCTAssertFalse(evidence.inputMonitoringAllowed)
    }
    func testDeniedNativeProbeIsNotOperationalDespiteTrustedFlag() {
        let evidence = PermissionEvidence(accessibilityTrusted: true, accessibilityProbe: .denied)
        XCTAssertTrue(evidence.granted(.accessibility))
        XCTAssertFalse(evidence.accessibilityOperational)
    }
    func testUnknownTargetIsNotMisreportedAsRevocation() {
        XCTAssertTrue(PermissionEvidence(accessibilityTrusted: true,
                                        accessibilityProbe: .unavailable).accessibilityOperational)
    }
    func testRevocationDoesNotLatchPreviousGrant() {
        let previouslyGranted = PermissionEvidence(accessibilityTrusted: true, accessibilityProbe: .working)
        let revoked = PermissionEvidence()
        XCTAssertTrue(previouslyGranted.accessibilityOperational)
        XCTAssertFalse(revoked.granted(.accessibility))
        XCTAssertFalse(revoked.accessibilityOperational)
    }
    func testShortcutTapModeFallsBackToListenOnly() {
        XCTAssertEqual(PermissionEvidence(accessibilityTrusted: true, accessibilityProbe: .working).shortcutTapMode, .active)
        XCTAssertEqual(PermissionEvidence(inputMonitoringAllowed: true).shortcutTapMode, .listenOnly)
        XCTAssertEqual(PermissionEvidence(accessibilityTrusted: true, accessibilityProbe: .denied,
                                          inputMonitoringAllowed: true).shortcutTapMode, .listenOnly)
        XCTAssertEqual(PermissionEvidence().shortcutTapMode, .unavailable)
    }
}
