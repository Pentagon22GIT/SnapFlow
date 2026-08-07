import XCTest
@testable import SnapFlow

final class MonitoringLifecyclePolicyTests: XCTestCase {
    func testSelectionPollingRequiresEveryLongLivedCondition() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))

        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: false,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: false,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: false,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: false,
            lockedPlacementCount: 2
        ))
        XCTAssertFalse(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 1
        ))
    }

    func testSelectionPollingAcceptsMoreThanTwoLockedPlacements() {
        XCTAssertTrue(MonitoringLifecyclePolicy.shouldRunSelectionPolling(
            controllerIsRunning: true,
            snapFlowIsEnabled: true,
            linkedResizeIsEnabled: true,
            connectedWindowRaiseIsEnabled: true,
            lockedPlacementCount: 4
        ))
    }
}
