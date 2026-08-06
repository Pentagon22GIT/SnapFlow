import XCTest
@testable import SnapFlow

final class AppSettingsTests: XCTestCase {
    func testRaiseConnectedWindowsOnClickIsEnabledByDefault() {
        XCTAssertTrue(AppSettings.defaultRaiseConnectedWindowsOnClick)
    }

    func testNativeResizeRecoveryIsOptIn() {
        XCTAssertFalse(AppSettings.defaultNativeResizeRecoveryEnabled)
    }

    func testNativeResizeRecoveryRequiresItsParentSetting() {
        XCTAssertFalse(AppSettings.isNativeResizeRecoveryActive(
            linkedResizeEnabled: false,
            recoveryEnabled: false
        ))
        XCTAssertFalse(AppSettings.isNativeResizeRecoveryActive(
            linkedResizeEnabled: false,
            recoveryEnabled: true
        ))
        XCTAssertFalse(AppSettings.isNativeResizeRecoveryActive(
            linkedResizeEnabled: true,
            recoveryEnabled: false
        ))
        XCTAssertTrue(AppSettings.isNativeResizeRecoveryActive(
            linkedResizeEnabled: true,
            recoveryEnabled: true
        ))
    }

    func testLightweightModeResizesNoWindowLive() {
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesMainWindowLive)
        XCTAssertFalse(LinkedResizeDisplayMode.lightweight.resizesLinkedWindowsLive)
    }

    func testDefaultModeResizesOnlyTheMainWindowLive() {
        XCTAssertTrue(LinkedResizeDisplayMode.mainOnly.resizesMainWindowLive)
        XCTAssertFalse(LinkedResizeDisplayMode.mainOnly.resizesLinkedWindowsLive)
    }

    func testAllWindowsModeAlwaysIncludesTheMainWindow() {
        XCTAssertTrue(LinkedResizeDisplayMode.allWindows.resizesMainWindowLive)
        XCTAssertTrue(LinkedResizeDisplayMode.allWindows.resizesLinkedWindowsLive)
    }

    func testNoModeCanResizeOnlyLinkedWindows() {
        XCTAssertFalse(LinkedResizeDisplayMode.allCases.contains {
            $0.resizesLinkedWindowsLive && !$0.resizesMainWindowLive
        })
    }
}
