enum MonitoringLifecyclePolicy {
    static func shouldRunSelectionPolling(
        controllerIsRunning: Bool,
        snapFlowIsEnabled: Bool,
        linkedResizeIsEnabled: Bool,
        connectedWindowRaiseIsEnabled: Bool,
        lockedPlacementCount: Int
    ) -> Bool {
        controllerIsRunning
            && snapFlowIsEnabled
            && linkedResizeIsEnabled
            && connectedWindowRaiseIsEnabled
            && lockedPlacementCount >= 2
    }
}
