import XCTest
@testable import SnapFlow

final class AppSettingsTests: XCTestCase {
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
