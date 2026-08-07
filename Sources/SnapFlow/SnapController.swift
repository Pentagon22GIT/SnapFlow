import AppKit
import ApplicationServices

private struct LockedPlacement {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let zone: SnapZone
    let displayID: CGDirectDisplayID
    var appliedFrame: CGRect
}

private struct ManualResizeParticipant {
    let window: ManagedWindow
    let zone: SnapZone
    let originalFrame: CGRect
    let sides: [SplitAxis: SplitBoundarySide]
    let constraintReference: CGSize
    var targetFrame: CGRect?
    var isSuspended = false
}

private struct ManualBoundaryGroup {
    let axis: SplitAxis
    let initialCoordinate: CGFloat
    var participantIDs: Set<String>
    var participantCoordinates: [CGFloat]
    var hasActivated: Bool
}

private struct ManualResizeApplication {
    let identity: String
    let participant: ManualResizeParticipant
    let activeAxes: Set<SplitAxis>
    let targetFrame: CGRect
    let connection: SplitConnectionKey
}

private struct WindowServerFrameCalibration {
    let serverFrame: CGRect
    let accessibilityFrame: CGRect

    func corrected(_ frame: CGRect) -> CGRect {
        SplitLayoutGeometry.calibratedFrame(
            frame,
            baselineLiveFrame: serverFrame,
            baselineReferenceFrame: accessibilityFrame
        )
    }
}

private struct SnapshotTransaction {
    let snapshots: [WindowSnapshot]
}

private struct InitialReflowFollower {
    let window: ManagedWindow
    let zone: SnapZone
    let axis: SplitAxis
    let side: SplitBoundarySide
    let originalFrame: CGRect
    let targetFrame: CGRect
    let constraintReference: CGSize
}

private struct InitialReflowPlan {
    let axes: Set<SplitAxis>
    let candidateStartFrame: CGRect
    let candidateTarget: CGRect
}

private enum InitialSplitDisposition {
    case accept
    case reflow(InitialReflowPlan)
    case reject
}

private struct ManualResizeSession {
    let driverIdentity: String
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let initialDriverFrame: CGRect
    var groups: [ManualBoundaryGroup]
    var participants: [String: ManualResizeParticipant]
}

private struct HandleResizeParticipant {
    let window: ManagedWindow
    let zone: SnapZone
    let originalFrame: CGRect
    let side: SplitBoundarySide
    let constraintReference: CGSize
    var targetFrame: CGRect
}

private struct HandleResizeSession {
    let handleID: String
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let axis: SplitAxis
    let mainIdentity: String
    let liveIdentities: Set<String>
    let virtualIdentities: Set<String>
    let allowedBoundary: ClosedRange<CGFloat>
    let schedulerGeneration: Int
    let snapshots: [WindowSnapshot]
    var participants: [String: HandleResizeParticipant]
    var boundaryCoordinate: CGFloat
}

private struct LayoutSession {
    let layoutZones: [SnapZone]
    var occupiedZones: [SnapZone: String]

    mutating func occupy(_ zone: SnapZone, stableIdentity: String) {
        occupiedZones[zone] = stableIdentity
    }

    var remainingZones: [SnapZone] {
        layoutZones.filter { occupiedZones[$0] == nil }
    }

    var occupiedStableIDs: Set<String> {
        Set(occupiedZones.values)
    }
}

private enum SnapEntryEdge {
    case left, right, top, bottom
}

private struct SnapTarget: Equatable {
    let displayID: CGDirectDisplayID
    let zone: SnapZone
}

private enum SideSnapEdge: Equatable {
    case left
    case right
}

private struct SideDwellContext: Equatable {
    let displayID: CGDirectDisplayID
    let edge: SideSnapEdge
}

final class SnapController {
    var isEnabled = true {
        didSet {
            if !isEnabled {
                invalidatePendingOperations()
                stopEscapeMonitoring()
                overlay.hide()
                picker.hide()
                virtualResizeOverlay.hideAll()
                resizeHandleOverlay.hideAll()
                cancelHandleResize(restoreOriginalFrames: true)
                resetDragState()
                activeSession = nil
            } else if oldValue != isEnabled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.refreshResizeHandles()
                }
            }
        }
    }

    private let windowService = AXWindowService()
    private let overlay = OverlayPanel()
    private let picker = WindowPickerPanel()
    private let virtualResizeOverlay = VirtualResizeOverlay()
    private let resizeHandleOverlay = ResizeHandleOverlay()
    private lazy var liveResizeScheduler = LiveResizeScheduler(windowService: windowService)
    private let settings = AppSettings.shared
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var recoveryTimer: Timer?
    private var lastInteractionAt = Date()
    private let assistTimeout: TimeInterval = 30
    private var activeTarget: SnapTarget?

    private var pendingDragWindow: ManagedWindow?
    private var pendingDragWindowFrame: CGRect?
    private var pendingDragMousePoint: CGPoint?
    private var pendingDragStartedInLikelyDragRegion = false
    private var pendingDragStartedNearResizeEdge = false
    private var isWindowMoveConfirmed = false
    private var sourceDragWindow: ManagedWindow?
    private var windowIDsAtDragStart: Set<String> = []
    private var pendingRestoreFrame: CGRect?
    private var dragRestoreFrameCandidate: CGRect?
    private var pendingGrabRatio: CGPoint?
    private var dragRestoreAnimationTimer: Timer?
    private var hasWindowActuallyMoved = false
    private var didStartDragRestore = false
    private var detachedCandidateID: String?
    private var detachedCandidateHitCount = 0
    private var manualResizeWindow: ManagedWindow?
    private var manualResizeSession: ManualResizeSession?
    private var manualResizeWindowServerCalibration: WindowServerFrameCalibration?
    private var lastManualResizeRefreshAt: TimeInterval = 0
    private let manualResizeRefreshInterval: TimeInterval = 1.0 / 60.0
    private let manualResizeDetectionTolerance: CGFloat = 0.5
    private var sideDwellTimer: Timer?
    private var sideDwellPulseTimer: Timer?
    private var sideDwellContext: SideDwellContext?
    private var expandedSideContext: SideDwellContext?

    private var dragWindow: ManagedWindow?
    private var dragDisplayID: CGDirectDisplayID?
    private var dragScreenFrame: CGRect?
    private var suppressedEntryEdge: SnapEntryEdge?
    private var suppressedDisplayID: CGDirectDisplayID?
    private var snapshotTransactions: [SnapshotTransaction] = []
    private var lockedPlacements: [String: LockedPlacement] = [:]
    private var detachedConnections: Set<SplitConnectionKey> = []
    private var constraintHints: [String: WindowConstraintHint] = [:]
    private var restoreFrames: [String: CGRect] = [:]
    private var activeSession: LayoutSession?
    private var isAssistPlacementPending = false
    private var interactionGeneration = 0
    private var pendingPlacementSnapshots: [String: WindowSnapshot] = [:]
    private var inFlightPlacementIDs: Set<String> = []
    private var handleResizeSession: HandleResizeSession?
    private var isHandleResizeFinalizing = false
    private var finalizingHandleResizeSession: HandleResizeSession?
    private var baseResizeHandleDescriptors: [ResizeHandleDescriptor] = []
    private var lastHandleOcclusionRefreshAt: TimeInterval = 0
    private let handleOcclusionRefreshInterval: TimeInterval = 1.0 / 20.0
    private var consecutiveHandleOcclusionFailures = 0
    private var handlePresentationGeneration = 0
    private var scheduledHandleOcclusionRetryGeneration: Int?
    private var hasValidatedCurrentHandleGeometry = false
    private let maximumImmediateHandleOcclusionFailures = 6
    private var groupRaiseGeneration = 0
    private var pendingGroupRaiseWorkItem: DispatchWorkItem?
    private let groupRaiseSettleDelay: TimeInterval = 0.03
    private let groupRaiseVerificationDelay: TimeInterval = 0.06
    private let maximumGroupRaiseAttempts = 2
    private var shouldRestoreHandlesAfterPointerInteraction = false
    private var isApplicationUIVisible = false

    init() {
        resizeHandleOverlay.onBegin = { [weak self] descriptor, point in
            self?.beginHandleResize(descriptor: descriptor, at: point)
        }
        resizeHandleOverlay.onChange = { [weak self] descriptor, point in
            self?.updateHandleResize(descriptor: descriptor, at: point)
        }
        resizeHandleOverlay.onEnd = { [weak self] descriptor, point in
            self?.finishHandleResize(descriptor: descriptor, at: point)
        }
        resizeHandleOverlay.onCancel = { [weak self] _ in
            self?.cancelHandleResize(restoreOriginalFrames: true)
        }
    }

    func start() {
        _ = windowService.requestPermissionIfNeeded()
        installEventMonitors()
        installRecoveryObservers()
        startRecoveryTimer()
        refreshResizeHandles()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        stopEscapeMonitoring()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultObservers.removeAll()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        invalidatePendingOperations()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        liveResizeScheduler.cancelAll()
        resetDragState()
        activeSession = nil
    }

    func reset() {
        isEnabled = true
        snapshotTransactions.removeAll()
        lockedPlacements.removeAll()
        detachedConnections.removeAll()
        constraintHints.removeAll()
        inFlightPlacementIDs.removeAll()
        restoreFrames.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        resetSideDwellState()
        invalidatePendingOperations()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
        cancelHandleResize(restoreOriginalFrames: true)
    }

    func restoreLast() {
        guard handleResizeSession == nil, !isHandleResizeFinalizing else { return }
        let visibleIDs = windowService.visibleStableIdentities()
        var targetIndex: Int?
        var staleIndices: [Int] = []

        for index in snapshotTransactions.indices.reversed() {
            let transaction = snapshotTransactions[index]
            if transaction.snapshots.contains(where: { visibleIDs.contains($0.stableIdentity) }) {
                targetIndex = index
                break
            }
            if transaction.snapshots.allSatisfy({
                !windowService.isWindowAlive(element: $0.element, pid: $0.pid)
            }) {
                staleIndices.append(index)
                for snapshot in transaction.snapshots {
                    lockedPlacements.removeValue(forKey: snapshot.stableIdentity)
                    removeConnections(for: snapshot.stableIdentity)
                    restoreFrames.removeValue(forKey: snapshot.stableIdentity)
                    constraintHints.removeValue(forKey: snapshot.stableIdentity)
                }
            }
        }

        staleIndices.sorted(by: >).forEach { snapshotTransactions.remove(at: $0) }
        guard let targetIndex, snapshotTransactions.indices.contains(targetIndex) else { return }
        let transaction = snapshotTransactions[targetIndex]
        let restorable = transaction.snapshots.filter {
            visibleIDs.contains($0.stableIdentity)
                && windowService.isWindowAlive(element: $0.element, pid: $0.pid)
        }
        guard !restorable.isEmpty else { return }
        invalidatePendingOperations()
        let generation = interactionGeneration
        var pending = restorable.count
        var allSucceeded = true

        for snapshot in restorable {
            windowService.restore(snapshot) { [weak self] succeeded in
                guard let self else { return }
                allSucceeded = allSucceeded && succeeded
                pending -= 1
                guard pending == 0,
                      allSucceeded,
                      self.interactionGeneration == generation else { return }

                if let currentIndex = self.snapshotTransactions.lastIndex(where: { candidate in
                    candidate.snapshots.count == transaction.snapshots.count
                        && zip(candidate.snapshots, transaction.snapshots).allSatisfy { pair in
                            pair.0.stableIdentity == pair.1.stableIdentity
                                && pair.0.frame == pair.1.frame
                                && CFEqual(pair.0.element, pair.1.element)
                        }
                }) {
                    self.snapshotTransactions.remove(at: currentIndex)
                }
                for restored in restorable {
                    self.lockedPlacements.removeValue(forKey: restored.stableIdentity)
                    self.removeConnections(for: restored.stableIdentity)
                    self.restoreFrames.removeValue(forKey: restored.stableIdentity)
                }
            }
        }
    }

    func clearLocks() {
        invalidatePendingOperations()
        lockedPlacements.removeAll()
        detachedConnections.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.hideAll()
    }

    func setApplicationUIVisible(_ isVisible: Bool) {
        isApplicationUIVisible = isVisible
        if isVisible {
            invalidatePendingGroupRaise()
            if handleResizeSession != nil {
                cancelHandleResize(restoreOriginalFrames: true)
            } else {
                resizeHandleOverlay.hideAll()
            }
        } else {
            refreshResizeHandles()
        }
    }

    func snapFocusedWindow(to zone: SnapZone) {
        guard handleResizeSession == nil, !isHandleResizeFinalizing else { return }
        guard isEnabled, ensurePermission(),
              let window = windowService.focusedWindow(),
              let screen = screen(containing: window.frame.center) ?? NSScreen.main else { return }
        invalidatePendingOperations()
        activeSession = nil
        snap(window, to: zone, on: screen, continueAssist: true)
    }

    private func installEventMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        let localMask: NSEvent.EventTypeMask = [mouseMask, .keyDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: localMask) { [weak self] event in
            if self?.resizeHandleOverlay.owns(window: event.window) == true {
                return event
            }
            self?.handle(event)
            return event
        }
    }

    private func startEscapeMonitoring() {
        guard globalEscapeMonitor == nil else { return }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.handleResizeSession != nil {
                    self.cancelHandleResize(restoreOriginalFrames: true)
                } else {
                    self.cancelAssist()
                }
            }
        }
    }

    private func stopEscapeMonitoring() {
        guard let globalEscapeMonitor else { return }
        NSEvent.removeMonitor(globalEscapeMonitor)
        self.globalEscapeMonitor = nil
    }


    private func installRecoveryObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceChange()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAssist()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAssist()
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshResizeHandleOcclusion(force: true)
        })

        defaultObservers.append(defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAssist()
        })

        defaultObservers.append(defaultCenter.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !self.settings.linkedResizeEnabled,
               self.handleResizeSession != nil {
                self.cancelHandleResize(restoreOriginalFrames: true)
            } else if self.handleResizeSession == nil {
                self.refreshResizeHandles()
            }
        })
    }

    private func startRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        if let recoveryTimer {
            RunLoop.main.add(recoveryTimer, forMode: .common)
        }
    }

    private func recoverIfNeeded() {
        guard isEnabled else { return }

        if handleResizeSession == nil,
           pendingDragWindow == nil,
           dragWindow == nil,
           manualResizeWindow == nil,
           !isWindowMoveConfirmed {
            refreshResizeHandles()
        }

        if (dragWindow != nil || pendingDragWindow != nil),
           !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let isManualResizeBeingFinished = finishManualResizeIfNeeded()
            if !isManualResizeBeingFinished {
                finishSmoothDragRestore(at: NSEvent.mouseLocation)
                resetDragState()
            }
            overlay.hide()
        }

        if activeSession != nil, !picker.isVisible, !isAssistPlacementPending {
            cancelAssist()
            return
        }

        if activeSession != nil,
           Date().timeIntervalSince(lastInteractionAt) >= assistTimeout {
            cancelAssist()
        }
    }

    private func refreshResizeHandles(
        using providedVisibleWindows: [ManagedWindow]? = nil,
        deferOcclusionRefresh: Bool = false
    ) {
        guard isEnabled,
              settings.linkedResizeEnabled,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending,
              !isApplicationUIVisible else {
            if handleResizeSession == nil {
                handlePresentationGeneration &+= 1
                baseResizeHandleDescriptors = []
                hasValidatedCurrentHandleGeometry = false
                resizeHandleOverlay.hideAll()
            }
            return
        }

        let visibleWindows = providedVisibleWindows ?? windowService.visibleWindows()
        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var descriptors: [ResizeHandleDescriptor] = []

        for screen in NSScreen.screens {
            guard let screenDisplayID = displayID(for: screen) else { continue }
            let placements = lockedPlacements.compactMap { identity, placement
                -> SplitPlacementGeometry? in
                guard placement.displayID == screenDisplayID,
                      !inFlightPlacementIDs.contains(identity),
                      let window = windowsByIdentity[identity] else { return nil }
                return SplitPlacementGeometry(
                    stableIdentity: identity,
                    zone: placement.zone,
                    frame: window.frame
                )
            }
            let geometries = SplitLayoutGeometry.resizeHandleGeometries(
                placements: placements,
                detachedConnections: detachedConnections
            )
            descriptors.append(contentsOf: geometries.map { geometry in
                let occlusionParticipants = geometry.participantIDs.sorted().compactMap {
                    identity -> WindowOcclusionParticipant? in
                    guard let window = windowsByIdentity[identity] else { return nil }
                    return WindowOcclusionParticipant(
                        pid: window.pid,
                        frame: window.frame,
                        windowID: window.cgWindowID
                    )
                }
                return ResizeHandleDescriptor(
                    id: resizeHandleIdentity(
                        displayID: screenDisplayID,
                        geometry: geometry
                    ),
                    displayID: screenDisplayID,
                    axis: geometry.axis,
                    coordinate: geometry.coordinate,
                    span: geometry.span,
                    screenFrame: screen.visibleFrame,
                    participantIDs: geometry.participantIDs,
                    occlusionParticipants: occlusionParticipants
                )
            })
        }
        let descriptorsChanged = descriptors != baseResizeHandleDescriptors
        if descriptorsChanged {
            handlePresentationGeneration &+= 1
            hasValidatedCurrentHandleGeometry = false
            consecutiveHandleOcclusionFailures = 0
        }
        baseResizeHandleDescriptors = descriptors
        if !hasValidatedCurrentHandleGeometry,
           !resizeHandleOverlay.hasPresentedHandles,
           !descriptors.isEmpty {
            resizeHandleOverlay.update(descriptors)
            resizeHandleOverlay.setInputSuspended(true)
        }
        guard !deferOcclusionRefresh else { return }
        refreshResizeHandleOcclusion(force: true)
    }

    private func refreshResizeHandleOcclusion(
        force: Bool = false,
        using providedSnapshot: [WindowOcclusionSnapshot]? = nil
    ) {
        guard isEnabled,
              settings.linkedResizeEnabled,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending,
              !isApplicationUIVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastHandleOcclusionRefreshAt
            >= handleOcclusionRefreshInterval else { return }
        lastHandleOcclusionRefreshAt = now

        let snapshot = providedSnapshot
            ?? windowService.windowOcclusionSnapshot()
        var visibleDescriptors: [ResizeHandleDescriptor] = []
        for descriptor in baseResizeHandleDescriptors {
            guard let occludingFrames = verifiedOccludingFrames(
                for: descriptor,
                in: snapshot
            ) else {
                handleIncompleteOcclusionSnapshot()
                return
            }
            if !descriptor.isOccluded(by: occludingFrames) {
                visibleDescriptors.append(descriptor)
            }
        }
        resizeHandleOverlay.update(visibleDescriptors)
        resizeHandleOverlay.setInputSuspended(false)
        hasValidatedCurrentHandleGeometry = true
        consecutiveHandleOcclusionFailures = 0
        if scheduledHandleOcclusionRetryGeneration
            == handlePresentationGeneration {
            scheduledHandleOcclusionRetryGeneration = nil
        }
    }

    private func verifiedOccludingFrames(
        for descriptor: ResizeHandleDescriptor,
        in snapshot: [WindowOcclusionSnapshot]
    ) -> [CGRect]? {
        guard descriptor.occlusionParticipants.count
                == descriptor.participantIDs.count,
              let occluders = windowService.occludingWindows(
                  above: descriptor.occlusionParticipants,
                  in: snapshot
              ) else { return nil }
        return occluders.compactMap {
            $0.layer == 0 ? $0.frame : nil
        }
    }

    private func handleIncompleteOcclusionSnapshot() {
        consecutiveHandleOcclusionFailures += 1

        // Window Server and Accessibility information can briefly disagree just
        // after a snap, activation, or Space transition. Do not destroy the
        // last known-good handles in that transient state. When there is no
        // previous presentation yet, show the base geometry as a safe fallback
        // until occlusion information becomes available.
        if !hasValidatedCurrentHandleGeometry,
           !resizeHandleOverlay.hasPresentedHandles,
           !baseResizeHandleDescriptors.isEmpty {
            resizeHandleOverlay.update(baseResizeHandleDescriptors)
        }
        resizeHandleOverlay.setInputSuspended(true)
        let retryGeneration = handlePresentationGeneration
        guard scheduledHandleOcclusionRetryGeneration != retryGeneration else {
            return
        }
        guard consecutiveHandleOcclusionFailures
                <= maximumImmediateHandleOcclusionFailures else {
            // The 1-second recovery pass will keep checking. Do not retain a
            // separate 2 Hz retry loop during a prolonged Window Server fault.
            return
        }
        scheduledHandleOcclusionRetryGeneration = retryGeneration
        let retryDelay: TimeInterval
        switch consecutiveHandleOcclusionFailures {
        case 0...2:
            retryDelay = 0.05
        case 3...5:
            retryDelay = 0.15
        default:
            retryDelay = 0.50
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self,
                  self.scheduledHandleOcclusionRetryGeneration
                    == retryGeneration else { return }
            self.scheduledHandleOcclusionRetryGeneration = nil
            guard self.handlePresentationGeneration == retryGeneration else {
                return
            }
            self.refreshResizeHandleOcclusion(force: true)
        }
    }

    private func resizeHandleIdentity(
        displayID: CGDirectDisplayID,
        geometry: SplitResizeHandleGeometry
    ) -> String {
        let axis = geometry.axis == .horizontal ? "h" : "v"
        let participants = geometry.participantIDs.sorted().joined(separator: "|")
        return "\(displayID):\(axis):\(participants)"
    }

    private func beginHandleResize(
        descriptor presentedDescriptor: ResizeHandleDescriptor,
        at point: CGPoint
    ) {
        guard isEnabled,
              settings.linkedResizeEnabled,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              ensurePermission(),
              let descriptor = baseResizeHandleDescriptors.first(where: {
                  $0.id == presentedDescriptor.id
              }),
              let screen = screen(withDisplayID: descriptor.displayID) else {
            refreshResizeHandles()
            return
        }

        let visibleWindows = windowService.visibleWindows()
        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let mainWindow = resolvedHandleMainWindow(
            participantIDs: descriptor.participantIDs,
            visibleWindows: visibleWindows
        ) else {
            refreshResizeHandles()
            return
        }

        var participants: [String: HandleResizeParticipant] = [:]
        var participantGeometry: [SplitResizeParticipantGeometry] = []
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        for identity in descriptor.participantIDs {
            guard let window = windowsByIdentity[identity],
                  let placement = lockedPlacements[identity],
                  placement.displayID == descriptor.displayID,
                  let side = SplitLayoutGeometry.boundarySide(
                      for: placement.zone,
                      axis: descriptor.axis
                  ) else { continue }
            let reference = constraintReference(
                for: window,
                zone: placement.zone,
                on: screen
            )
            let referenceLength = descriptor.axis == .horizontal
                ? reference.width
                : reference.height
            participants[identity] = HandleResizeParticipant(
                window: window,
                zone: placement.zone,
                originalFrame: window.frame,
                side: side,
                constraintReference: reference,
                targetFrame: window.frame
            )
            participantGeometry.append(SplitResizeParticipantGeometry(
                stableIdentity: identity,
                frame: window.frame,
                side: side,
                minimumLength: max(referenceLength * (1 - tolerance), 1)
            ))
        }
        guard participants.count >= 2,
              participants[mainWindow.stableIdentity] != nil,
              let allowedBoundary = SplitLayoutGeometry.allowedBoundaryRange(
                  axis: descriptor.axis,
                  participants: participantGeometry,
                  screenFrame: screen.visibleFrame
              ) else {
            refreshResizeHandles()
            return
        }

        // A Window Server change can arrive between the last presentation
        // update and mouseDown. Revalidate immediately before AXRaise so a
        // stale visible handle cannot pull its participants above an
        // intervening window. No interaction state has been mutated yet.
        let occlusionSnapshot = windowService.windowOcclusionSnapshot()
        guard let occludingFrames = verifiedOccludingFrames(
            for: descriptor,
            in: occlusionSnapshot
        ) else {
            handleIncompleteOcclusionSnapshot()
            return
        }
        guard !descriptor.isOccluded(by: occludingFrames) else {
            refreshResizeHandleOcclusion(
                force: true,
                using: occlusionSnapshot
            )
            return
        }

        invalidatePendingOperations()
        activeSession = nil
        picker.hide()
        overlay.hide()
        virtualResizeOverlay.hideAll()
        resetDragState()

        // Raise only the participants of this still-active handle. Do not
        // activate every application here; AXRaise preserves the drag event,
        // while the clicked/main participant is raised last.
        raiseWindows(
            participants.values.map(\.window),
            withMainWindow: mainWindow
        )

        let allIdentities = Set(participants.keys)
        let liveIdentities: Set<String>
        switch settings.linkedResizeDisplayMode {
        case .lightweight:
            liveIdentities = []
        case .mainOnly:
            liveIdentities = [mainWindow.stableIdentity]
        case .allWindows:
            liveIdentities = allIdentities
        }
        let virtualIdentities = allIdentities.subtracting(liveIdentities)
        let snapshots = participants.values.map { windowService.snapshot($0.window) }
        let schedulerGeneration = liveResizeScheduler.begin()
        handleResizeSession = HandleResizeSession(
            handleID: descriptor.id,
            displayID: descriptor.displayID,
            screenFrame: screen.visibleFrame,
            axis: descriptor.axis,
            mainIdentity: mainWindow.stableIdentity,
            liveIdentities: liveIdentities,
            virtualIdentities: virtualIdentities,
            allowedBoundary: allowedBoundary,
            schedulerGeneration: schedulerGeneration,
            snapshots: snapshots,
            participants: participants,
            boundaryCoordinate: descriptor.coordinate
        )
        inFlightPlacementIDs.formUnion(allIdentities)
        resizeHandleOverlay.beginInteraction(with: descriptor.id)
        startEscapeMonitoring()
        updateHandleResize(descriptor: descriptor, at: point)
    }

    private func resolvedHandleMainWindow(
        participantIDs: Set<String>,
        visibleWindows: [ManagedWindow]
    ) -> ManagedWindow? {
        if let focused = windowService.focusedWindow(),
           participantIDs.contains(focused.stableIdentity),
           let matching = visibleWindows.first(where: {
               $0.stableIdentity == focused.stableIdentity
           }) {
            return matching
        }
        return visibleWindows.first { participantIDs.contains($0.stableIdentity) }
    }

    private func updateHandleResize(
        descriptor: ResizeHandleDescriptor,
        at point: CGPoint
    ) {
        guard var session = handleResizeSession,
              session.handleID == descriptor.id else { return }
        let proposed = session.axis == .horizontal ? point.x : point.y
        let coordinate = min(
            max(proposed, session.allowedBoundary.lowerBound),
            session.allowedBoundary.upperBound
        )
        let geometry = session.participants.map { identity, participant in
            SplitResizeParticipantGeometry(
                stableIdentity: identity,
                frame: participant.originalFrame,
                side: participant.side,
                minimumLength: 1
            )
        }
        let targetFrames = SplitLayoutGeometry.resizedFrames(
            meetingBoundary: coordinate,
            axis: session.axis,
            participants: geometry
        )
        for (identity, targetFrame) in targetFrames {
            guard var participant = session.participants[identity] else { continue }
            participant.targetFrame = targetFrame
            session.participants[identity] = participant
        }
        session.boundaryCoordinate = coordinate
        handleResizeSession = session

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let liveRequests = session.liveIdentities.compactMap { identity
            -> LiveResizeRequest? in
            guard let participant = session.participants[identity] else { return nil }
            return LiveResizeRequest(
                stableIdentity: identity,
                element: participant.window.element,
                targetFrame: participant.targetFrame,
                primaryScreenTop: primaryTop
            )
        }
        liveResizeScheduler.submit(
            liveRequests,
            generation: session.schedulerGeneration
        )

        let virtualItems = session.virtualIdentities.compactMap { identity
            -> VirtualResizeItem? in
            guard let participant = session.participants[identity] else { return nil }
            return VirtualResizeItem(
                stableIdentity: identity,
                originalFrame: participant.originalFrame,
                targetFrame: participant.targetFrame,
                appIcon: participant.window.appIcon
            )
        }
        let liveFrames = session.liveIdentities.compactMap {
            session.participants[$0]?.targetFrame
        }
        virtualResizeOverlay.update(
            items: virtualItems,
            liveFrames: liveFrames,
            screenFrame: session.screenFrame
        )
        let movedDescriptor = ResizeHandleDescriptor(
            id: descriptor.id,
            displayID: descriptor.displayID,
            axis: descriptor.axis,
            coordinate: coordinate,
            span: descriptor.span,
            screenFrame: descriptor.screenFrame,
            participantIDs: descriptor.participantIDs
        )
        resizeHandleOverlay.update([movedDescriptor])
    }

    private func finishHandleResize(
        descriptor: ResizeHandleDescriptor,
        at point: CGPoint
    ) {
        guard handleResizeSession?.handleID == descriptor.id else { return }
        updateHandleResize(descriptor: descriptor, at: point)
        guard let session = handleResizeSession else { return }
        updateHandleSettlementOverlay(session, restoreOriginalFrames: false)
        handleResizeSession = nil
        isHandleResizeFinalizing = true
        finalizingHandleResizeSession = session
        stopEscapeMonitoring()
        liveResizeScheduler.stop(generation: session.schedulerGeneration) { [weak self] in
            self?.completeHandleResize(session)
        }
    }

    private func completeHandleResize(_ session: HandleResizeSession) {
        guard isHandleResizeFinalizing,
              finalizingHandleResizeSession?.schedulerGeneration
                == session.schedulerGeneration else { return }
        let operationGeneration = interactionGeneration
        let identities = Set(session.participants.keys)
        var pending = session.participants.count
        var allSucceeded = true
        var acceptedWindows: [String: ManagedWindow] = [:]

        for (identity, participant) in session.participants {
            windowService.setFrameAnchoredReliably(
                participant.targetFrame,
                sizeConstraintAnchor: participant.zone.sizeConstraintAnchor,
                requiredOuterEdges: participant.zone.requiredOuterEdges,
                for: participant.window.element
            ) { [weak self] succeeded in
                guard let self else { return }
                guard self.isHandleResizeFinalizing,
                      self.finalizingHandleResizeSession?.schedulerGeneration
                        == session.schedulerGeneration else { return }
                let refreshed = self.windowService.refreshed(participant.window)
                let edgesMatch = refreshed.map {
                    self.matchesRequiredOuterEdges(
                        $0.frame,
                        targetFrame: participant.targetFrame,
                        requiredEdges: participant.zone.requiredOuterEdges
                    )
                } ?? false
                allSucceeded = allSucceeded && succeeded && edgesMatch
                if let refreshed {
                    acceptedWindows[identity] = refreshed
                }
                pending -= 1
                guard pending == 0 else { return }

                if allSucceeded,
                   self.interactionGeneration == operationGeneration {
                    for (acceptedIdentity, accepted) in acceptedWindows {
                        self.observeConstraint(
                            for: accepted,
                            requestedSize: session.participants[acceptedIdentity]?.targetFrame.size
                                ?? accepted.frame.size
                        )
                        if var placement = self.lockedPlacements[acceptedIdentity] {
                            placement.appliedFrame = accepted.frame
                            self.lockedPlacements[acceptedIdentity] = placement
                        }
                    }
                    for first in identities {
                        for second in identities where first < second {
                            self.detachedConnections.remove(
                                SplitConnectionKey(first, second)
                            )
                        }
                    }
                    for window in acceptedWindows.values
                        where window.stableIdentity != session.mainIdentity {
                        self.windowService.raise(window)
                    }
                    if let main = acceptedWindows[session.mainIdentity] {
                        self.windowService.focus(main)
                    }
                    self.finishHandleResizePresentation(
                        identities: identities,
                        schedulerGeneration: session.schedulerGeneration
                    )
                } else {
                    self.rollbackTransaction(session.snapshots) { [weak self] _ in
                        self?.finishHandleResizePresentation(
                            identities: identities,
                            schedulerGeneration: session.schedulerGeneration
                        )
                    }
                }
            }
        }
    }

    private func finishHandleResizePresentation(
        identities: Set<String>,
        schedulerGeneration: Int
    ) {
        guard isHandleResizeFinalizing,
              finalizingHandleResizeSession?.schedulerGeneration
                == schedulerGeneration else { return }
        isHandleResizeFinalizing = false
        finalizingHandleResizeSession = nil
        inFlightPlacementIDs.subtract(identities)
        virtualResizeOverlay.hideAll()
        resizeHandleOverlay.endInteraction()
        refreshResizeHandles()
    }

    private func cancelHandleResize(restoreOriginalFrames: Bool) {
        guard let session = handleResizeSession else {
            resizeHandleOverlay.endInteraction()
            return
        }
        updateHandleSettlementOverlay(
            session,
            restoreOriginalFrames: restoreOriginalFrames
        )
        handleResizeSession = nil
        isHandleResizeFinalizing = true
        finalizingHandleResizeSession = session
        stopEscapeMonitoring()
        let identities = Set(session.participants.keys)
        liveResizeScheduler.stop(generation: session.schedulerGeneration) { [weak self] in
            guard let self else { return }
            guard restoreOriginalFrames else {
                self.finishHandleResizePresentation(
                    identities: identities,
                    schedulerGeneration: session.schedulerGeneration
                )
                return
            }
            self.rollbackTransaction(session.snapshots) { [weak self] _ in
                self?.finishHandleResizePresentation(
                    identities: identities,
                    schedulerGeneration: session.schedulerGeneration
                )
            }
        }
    }

    private func updateHandleSettlementOverlay(
        _ session: HandleResizeSession,
        restoreOriginalFrames: Bool
    ) {
        guard !session.virtualIdentities.isEmpty else {
            virtualResizeOverlay.hideAll()
            return
        }
        let items = session.virtualIdentities.compactMap { identity
            -> VirtualResizeItem? in
            guard let participant = session.participants[identity] else {
                return nil
            }
            let displayedTarget = restoreOriginalFrames
                ? participant.originalFrame
                : participant.targetFrame
            return VirtualResizeItem(
                stableIdentity: identity,
                originalFrame: participant.originalFrame.union(participant.targetFrame),
                targetFrame: displayedTarget,
                appIcon: participant.window.appIcon
            )
        }
        virtualResizeOverlay.update(
            items: items,
            liveFrames: session.liveIdentities.compactMap {
                session.participants[$0]?.targetFrame
            },
            screenFrame: session.screenFrame
        )
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }
        lastInteractionAt = Date()

        if handleResizeSession == nil, event.type == .leftMouseDragged {
            refreshResizeHandleOcclusion()
        }

        if handleResizeSession != nil {
            if event.type == .keyDown, event.keyCode == 53 {
                cancelHandleResize(restoreOriginalFrames: true)
            }
            return
        }
        if isHandleResizeFinalizing {
            return
        }

        if event.type == .keyDown, event.keyCode == 53 {
            cancelAssist()
            return
        }
        guard ensurePermission() else { return }

        switch event.type {
        case .leftMouseDown:
            let point = NSEvent.mouseLocation
            invalidatePendingGroupRaise()

            if picker.isVisible && picker.containsScreenPoint(point) {
                return
            }
            if isAssistPlacementPending {
                cancelAssist()
                return
            }
            dismissAssistPresentationForPointerDown()
            beginPendingDrag(at: point)

        case .leftMouseDragged:
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                cancelAssist()
                return
            }
            guard activeSession == nil else { return }

            let point = NSEvent.mouseLocation
            let adoptedDetachedWindow = adoptDetachedWindowIfNeeded(at: point, allowImmediate: false)
            if !adoptedDetachedWindow {
                if (pendingDragStartedNearResizeEdge || !pendingDragStartedInLikelyDragRegion),
                   trackManualResizeIfNeeded() {
                    return
                }
                if !isWindowMoveConfirmed {
                    guard confirmWindowMove(at: point) else { return }
                } else if !hasWindowActuallyMoved {
                    detectActualWindowMovementIfNeeded(at: point)
                }
            }
            handleDrag(at: point)

        case .leftMouseUp:
            if isAssistPlacementPending {
                return
            }
            let mousePoint = NSEvent.mouseLocation
            let wasPlainClick = activeSession == nil
                && manualResizeWindow == nil
                && !isWindowMoveConfirmed
                && !hasWindowActuallyMoved
                && !didStartDragRestore
            if finishManualResizeIfNeeded() {
                shouldRestoreHandlesAfterPointerInteraction = false
                overlay.hide()
                return
            }
            if wasPlainClick {
                scheduleConnectedGroupRaiseForPlainClick(at: mousePoint)
            }
            if activeSession == nil {
                handleDrop(at: mousePoint)
            } else if !picker.isVisible {
                cancelAssist()
            }
            if !wasPlainClick {
                refreshResizeHandleOcclusion(force: true)
            } else if shouldRestoreHandlesAfterPointerInteraction {
                refreshResizeHandles()
            }
            shouldRestoreHandlesAfterPointerInteraction = false

        default:
            break
        }
    }

    private func beginPendingDrag(at point: CGPoint) {
        guard let window = windowService.focusedWindow(),
              windowService.canMoveAndResize(window) else {
            pendingDragWindow = nil
            pendingDragWindowFrame = nil
            pendingDragMousePoint = nil
            return
        }
        sourceDragWindow = window
        windowIDsAtDragStart = windowService.windowIdentities(forPID: window.pid)
        pendingDragWindow = window
        pendingDragWindowFrame = window.frame
        pendingDragMousePoint = point
        pendingDragStartedInLikelyDragRegion = isLikelyWindowDragRegion(point, window: window)
        pendingDragStartedNearResizeEdge = isNearWindowResizeEdge(point, frame: window.frame)
        pendingGrabRatio = grabRatio(at: point, in: window.frame)
        let storedRestoreFrame = restoreFrames[window.stableIdentity]
        let isKnownSnappedWindow = storedRestoreFrame != nil
        pendingRestoreFrame = isKnownSnappedWindow ? storedRestoreFrame : nil
        dragRestoreFrameCandidate = storedRestoreFrame ?? window.frame
        isWindowMoveConfirmed = false
        hasWindowActuallyMoved = false
        didStartDragRestore = false
        detachedCandidateID = nil
        detachedCandidateHitCount = 0
        manualResizeWindow = nil
        manualResizeSession = nil
        manualResizeWindowServerCalibration = nil
        lastManualResizeRefreshAt = 0
        virtualResizeOverlay.hideAll()
        prepareManualResizeIfNeeded(at: point, driver: window)
    }

    private func dismissAssistPresentationForPointerDown() {
        shouldRestoreHandlesAfterPointerInteraction = activeSession != nil
            || picker.isVisible
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resetDragState()
        activeSession = nil
    }

    private func prepareManualResizeIfNeeded(at point: CGPoint, driver: ManagedWindow) {
        guard settings.nativeResizeRecoveryIsActive,
              pendingDragStartedNearResizeEdge,
              let placement = lockedPlacements[driver.stableIdentity] else { return }
        var axes: Set<SplitAxis> = []
        for axis in SplitAxis.allCases {
            guard let side = SplitLayoutGeometry.boundarySide(
                for: placement.zone,
                axis: axis
            ) else { continue }
            let coordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: driver.frame,
                side: side,
                axis: axis
            )
            let mouseCoordinate = axis == .horizontal ? point.x : point.y
            if abs(mouseCoordinate - coordinate) <= 8 {
                axes.insert(axis)
            }
        }
        guard !axes.isEmpty else { return }
        let trackedDriver = windowService.resolvingWindowServerIdentity(driver)
        if let serverFrame = windowService.windowServerFrame(trackedDriver) {
            manualResizeWindowServerCalibration = WindowServerFrameCalibration(
                serverFrame: serverFrame,
                accessibilityFrame: trackedDriver.frame
            )
        }
        pendingDragWindow = trackedDriver
        sourceDragWindow = trackedDriver
        guard let session = makeManualResizeSession(
            driver: trackedDriver,
            originalFrame: trackedDriver.frame,
            candidateAxes: axes
        ) else { return }
        manualResizeSession = session
        protectManualResizePlacements(
            driverIdentity: trackedDriver.stableIdentity,
            session: session
        )
        virtualResizeOverlay.prepare(
            items: session.participants.map { identity, participant in
                VirtualResizeItem(
                    stableIdentity: identity,
                    originalFrame: participant.originalFrame,
                    targetFrame: participant.originalFrame,
                    appIcon: participant.window.appIcon
                )
            },
            screenFrame: session.screenFrame
        )
    }

    private func trackManualResizeIfNeeded() -> Bool {
        guard !isWindowMoveConfirmed,
              !hasWindowActuallyMoved,
              !didStartDragRestore else {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastManualResizeRefreshAt < manualResizeRefreshInterval {
            return manualResizeWindow != nil
        }
        lastManualResizeRefreshAt = now

        if let manualResizeWindow {
            guard let currentFrame = manualTrackingFrame(for: manualResizeWindow) else {
                return true
            }
            guard currentFrame != manualResizeWindow.frame else { return true }
            let current = manualResizeWindow.replacingFrame(currentFrame)
            self.manualResizeWindow = current
            updateManualResizeSession(with: current)
            overlay.hide()
            activeTarget = nil
            return true
        }

        guard let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame,
              let currentFrame = manualTrackingFrame(for: originalWindow) else {
            return false
        }
        let currentWindow = originalWindow.replacingFrame(currentFrame)

        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width)
            > manualResizeDetectionTolerance
            || abs(currentWindow.frame.height - originalFrame.height)
                > manualResizeDetectionTolerance
        guard sizeChanged else { return false }

        manualResizeWindow = currentWindow
        if settings.nativeResizeRecoveryIsActive,
           manualResizeSession == nil {
            manualResizeSession = makeManualResizeSession(
                driver: currentWindow,
                originalFrame: originalFrame
            )
        }
        if let manualResizeSession {
            protectManualResizePlacements(
                driverIdentity: currentWindow.stableIdentity,
                session: manualResizeSession
            )
        }
        updateManualResizeSession(with: currentWindow)
        dragWindow = nil
        isWindowMoveConfirmed = false
        overlay.hide()
        activeTarget = nil
        return true
    }

    private func finishManualResizeIfNeeded() -> Bool {
        guard !isWindowMoveConfirmed,
              !hasWindowActuallyMoved,
              !didStartDragRestore else {
            return false
        }

        guard let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame else {
            return false
        }
        let sourceWindow = manualResizeWindow ?? originalWindow
        guard let currentFrame = windowService.refreshedFrame(sourceWindow) else {
            let hadManualResize = manualResizeWindow != nil
            releaseManualResizeProtection(
                driverIdentity: originalWindow.stableIdentity,
                session: manualResizeSession
            )
            manualResizeSession = nil
            virtualResizeOverlay.hideAll()
            if hadManualResize {
                resetDragState()
            }
            return hadManualResize
        }
        let currentWindow = sourceWindow.replacingFrame(currentFrame)

        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width)
            > manualResizeDetectionTolerance
            || abs(currentWindow.frame.height - originalFrame.height)
                > manualResizeDetectionTolerance
        guard manualResizeWindow != nil || sizeChanged else {
            releaseManualResizeProtection(
                driverIdentity: originalWindow.stableIdentity,
                session: manualResizeSession
            )
            manualResizeSession = nil
            virtualResizeOverlay.hideAll()
            return false
        }

        guard settings.nativeResizeRecoveryIsActive,
              manualResizeSession != nil else {
            releaseManualResizeProtection(
                driverIdentity: currentWindow.stableIdentity,
                session: manualResizeSession
            )
            manualResizeSession = nil
            virtualResizeOverlay.hideAll()
            lockedPlacements.removeValue(forKey: currentWindow.stableIdentity)
            removeConnections(for: currentWindow.stableIdentity)
            resetDragState()
            return true
        }

        beginManualResizeSettlement(currentWindow)
        return true
    }

    private func manualTrackingFrame(for window: ManagedWindow) -> CGRect? {
        if settings.linkedResizeEnabled,
           manualResizeSession != nil,
           let calibration = manualResizeWindowServerCalibration,
           let serverFrame = windowService.windowServerFrame(window) {
            return calibration.corrected(serverFrame)
        }
        return windowService.refreshedFrame(window)
    }

    private func beginManualResizeSettlement(_ driver: ManagedWindow) {
        let generation = interactionGeneration
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        var protectedIDs: Set<String> = [driver.stableIdentity]
        if let session = manualResizeSession {
            protectedIDs.formUnion(session.participants.keys)
        }
        inFlightPlacementIDs.formUnion(protectedIDs)
        var previousFrame = driver.frame
        var stableSamples = 0

        func sample() {
            guard generation == interactionGeneration,
                  let frame = windowService.refreshedFrame(driver) else {
                inFlightPlacementIDs.subtract(protectedIDs)
                virtualResizeOverlay.hideAll()
                resetDragState()
                return
            }
            let stable = SplitLayoutGeometry.framesMatchForSettlement(
                frame,
                previousFrame
            )
            stableSamples = stable ? stableSamples + 1 : 0
            previousFrame = frame
            let now = ProcessInfo.processInfo.systemUptime
            if stableSamples >= 2 || now >= deadline {
                let settledDriver = driver.replacingFrame(frame)
                completeManualResize(settledDriver)
                resetDragState()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                sample()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
            sample()
        }
    }

    private func protectManualResizePlacements(
        driverIdentity: String,
        session: ManualResizeSession
    ) {
        inFlightPlacementIDs.insert(driverIdentity)
        inFlightPlacementIDs.formUnion(session.participants.keys)
    }

    private func releaseManualResizeProtection(
        driverIdentity: String,
        session: ManualResizeSession?
    ) {
        inFlightPlacementIDs.remove(driverIdentity)
        if let session {
            inFlightPlacementIDs.subtract(session.participants.keys)
        }
    }

    private func makeManualResizeSession(
        driver: ManagedWindow,
        originalFrame: CGRect,
        candidateAxes: Set<SplitAxis>? = nil
    ) -> ManualResizeSession? {
        guard let driverPlacement = lockedPlacements[driver.stableIdentity],
              let screen = screen(withDisplayID: driverPlacement.displayID) else { return nil }

        var windowsByIdentity: [String: ManagedWindow] = [:]
        for (identity, placement) in lockedPlacements {
            guard placement.displayID == driverPlacement.displayID,
                  let app = NSRunningApplication(processIdentifier: placement.pid),
                  !app.isTerminated else { continue }
            windowsByIdentity[identity] = ManagedWindow(
                element: placement.element,
                pid: placement.pid,
                title: "",
                appIcon: app.icon,
                frame: placement.appliedFrame,
                isMinimized: false,
                isFullscreen: false,
                cgWindowID: nil
            )
        }
        let placements = lockedPlacements.filter { identity, placement in
            identity != driver.stableIdentity
                && placement.displayID == driverPlacement.displayID
                && windowsByIdentity[identity] != nil
                && !detachedConnections.contains(
                    SplitConnectionKey(driver.stableIdentity, identity)
                )
        }
        var groups: [ManualBoundaryGroup] = []

        for axis in SplitAxis.allCases {
            if let candidateAxes, !candidateAxes.contains(axis) { continue }
            guard let driverSide = SplitLayoutGeometry.boundarySide(
                for: driverPlacement.zone,
                axis: axis
            ) else { continue }
            let initialCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: originalFrame,
                side: driverSide,
                axis: axis
            )
            let currentCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: driver.frame,
                side: driverSide,
                axis: axis
            )
            if candidateAxes == nil,
               abs(currentCoordinate - initialCoordinate) <= 1.5 {
                continue
            }

            groups.append(contentsOf: makeManualBoundaryGroups(
                axis: axis,
                driverZone: driverPlacement.zone,
                driverSide: driverSide,
                initialCoordinate: initialCoordinate,
                placements: placements,
                windowsByIdentity: windowsByIdentity
            ))
        }

        guard !groups.isEmpty else { return nil }
        let participantIDs = groups.reduce(into: Set<String>()) {
            $0.formUnion($1.participantIDs)
        }
        var participants: [String: ManualResizeParticipant] = [:]
        for identity in participantIDs {
            guard let placement = lockedPlacements[identity],
                  let window = windowsByIdentity[identity] else { continue }
            var sides: [SplitAxis: SplitBoundarySide] = [:]
            for axis in SplitAxis.allCases where groups.contains(where: {
                $0.axis == axis && $0.participantIDs.contains(identity)
            }) {
                sides[axis] = SplitLayoutGeometry.boundarySide(
                    for: placement.zone,
                    axis: axis
                )
            }
            participants[identity] = ManualResizeParticipant(
                window: window,
                zone: placement.zone,
                originalFrame: window.frame,
                sides: sides,
                constraintReference: constraintReference(
                    for: window,
                    zone: placement.zone,
                    on: screen
                )
            )
        }

        guard !participants.isEmpty else { return nil }
        return ManualResizeSession(
            driverIdentity: driver.stableIdentity,
            displayID: driverPlacement.displayID,
            screenFrame: screen.visibleFrame,
            initialDriverFrame: originalFrame,
            groups: groups,
            participants: participants
        )
    }

    private func makeManualBoundaryGroups(
        axis: SplitAxis,
        driverZone: SnapZone,
        driverSide: SplitBoundarySide,
        initialCoordinate: CGFloat,
        placements: [String: LockedPlacement],
        windowsByIdentity: [String: ManagedWindow]
    ) -> [ManualBoundaryGroup] {
        let driverBands = SplitLayoutGeometry.perpendicularBands(
            for: driverZone,
            axis: axis
        )
        var result: [ManualBoundaryGroup] = []

        for band in [SplitPerpendicularBand.first, .second] {
            let members = placements.compactMap { identity, placement
                -> (String, LockedPlacement, ManagedWindow, SplitBoundarySide)? in
                guard SplitLayoutGeometry.perpendicularBands(
                    for: placement.zone,
                    axis: axis
                ).contains(band),
                      let side = SplitLayoutGeometry.boundarySide(
                          for: placement.zone,
                          axis: axis
                      ),
                      let window = windowsByIdentity[identity] else { return nil }
                return (identity, placement, window, side)
            }
            guard !members.isEmpty else { continue }

            var occupiedSides = Set(members.map { $0.3 })
            if driverBands.contains(band) {
                occupiedSides.insert(driverSide)
            }
            guard occupiedSides.count == 2 else { continue }

            let coordinates = members.map {
                SplitLayoutGeometry.boundaryCoordinate(
                    of: $0.2.frame,
                    side: $0.3,
                    axis: axis
                )
            }
            result.append(ManualBoundaryGroup(
                axis: axis,
                initialCoordinate: initialCoordinate,
                participantIDs: Set(members.map { $0.0 }),
                participantCoordinates: coordinates,
                hasActivated: SplitLayoutGeometry.hasReachedBoundary(
                    initialCoordinate: initialCoordinate,
                    currentCoordinate: initialCoordinate,
                    participantCoordinates: coordinates
                )
            ))
        }

        var merged: [ManualBoundaryGroup] = []
        for group in result {
            if let index = merged.firstIndex(where: {
                !$0.participantIDs.isDisjoint(with: group.participantIDs)
            }) {
                merged[index].participantIDs.formUnion(group.participantIDs)
                merged[index].participantCoordinates.append(contentsOf: group.participantCoordinates)
                merged[index].hasActivated = merged[index].hasActivated && group.hasActivated
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    private func updateManualResizeSession(with driver: ManagedWindow) {
        guard var session = manualResizeSession,
              session.driverIdentity == driver.stableIdentity else { return }

        for index in session.groups.indices where !session.groups[index].hasActivated {
            let group = session.groups[index]
            guard let driverSide = SplitLayoutGeometry.boundarySide(
                for: lockedPlacements[driver.stableIdentity]?.zone ?? .maximize,
                axis: group.axis
            ) else { continue }
            let currentCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: driver.frame,
                side: driverSide,
                axis: group.axis
            )
            session.groups[index].hasActivated = SplitLayoutGeometry.hasReachedBoundary(
                initialCoordinate: group.initialCoordinate,
                currentCoordinate: currentCoordinate,
                participantCoordinates: group.participantCoordinates
            )
        }

        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var overlayItems: [VirtualResizeItem] = []
        for identity in Array(session.participants.keys) {
            guard var participant = session.participants[identity] else { continue }
            let activeAxes = Set(session.groups.compactMap { group in
                group.hasActivated && group.participantIDs.contains(identity)
                    ? group.axis
                    : nil
            })
            guard !activeAxes.isEmpty else {
                participant.targetFrame = nil
                participant.isSuspended = false
                session.participants[identity] = participant
                continue
            }

            var target = participant.originalFrame
            for axis in SplitAxis.allCases where activeAxes.contains(axis) {
                guard let side = participant.sides[axis],
                      let driverSide = SplitLayoutGeometry.boundarySide(
                          for: lockedPlacements[driver.stableIdentity]?.zone ?? .maximize,
                          axis: axis
                      ) else { continue }
                let coordinate = SplitLayoutGeometry.boundaryCoordinate(
                    of: driver.frame,
                    side: driverSide,
                    axis: axis
                )
                target = SplitLayoutGeometry.frame(
                    target,
                    meetingBoundary: coordinate,
                    side: side,
                    axis: axis
                )
            }
            participant.targetFrame = target
            let compressionDegrees = activeAxes.map { axis -> CGFloat in
                let targetLength = axis == .horizontal ? target.width : target.height
                let referenceLength = axis == .horizontal
                    ? participant.constraintReference.width
                    : participant.constraintReference.height
                return SplitLayoutGeometry.compressionRatio(
                    targetLength: targetLength,
                    referenceLength: referenceLength
                )
            }
            participant.isSuspended = SplitLayoutGeometry.remainsSuspended(
                wasSuspended: participant.isSuspended,
                compressionRatios: compressionDegrees,
                tolerance: tolerance
            )

            if !participant.isSuspended {
                overlayItems.append(VirtualResizeItem(
                    stableIdentity: identity,
                    originalFrame: participant.originalFrame,
                    targetFrame: target,
                    appIcon: participant.window.appIcon
                ))
            }
            session.participants[identity] = participant
        }
        virtualResizeOverlay.update(
            items: overlayItems,
            driverFrame: driver.frame,
            screenFrame: session.screenFrame
        )
        manualResizeSession = session
    }

    private func completeManualResize(_ driver: ManagedWindow) {
        updateManualResizeSession(with: driver)
        guard let session = manualResizeSession else {
            if var placement = lockedPlacements[driver.stableIdentity] {
                placement.appliedFrame = driver.frame
                lockedPlacements[driver.stableIdentity] = placement
            }
            inFlightPlacementIDs.remove(driver.stableIdentity)
            virtualResizeOverlay.hideAll()
            return
        }
        manualResizeSession = nil

        let generation = interactionGeneration
        let threshold = CGFloat(settings.layoutIntrusionTolerance)
        var applications: [ManualResizeApplication] = []

        for (identity, participant) in session.participants {
            let connection = SplitConnectionKey(driver.stableIdentity, identity)
            let participantGroups = session.groups.filter {
                $0.participantIDs.contains(identity)
            }
            let activeAxes = Set(participantGroups.compactMap {
                $0.hasActivated ? $0.axis : nil
            })
            guard let target = participant.targetFrame, !activeAxes.isEmpty else {
                let degree = participantGroups.map { group -> CGFloat in
                    guard let driverSide = SplitLayoutGeometry.boundarySide(
                        for: lockedPlacements[driver.stableIdentity]?.zone ?? .maximize,
                        axis: group.axis
                    ) else { return 0 }
                    let currentCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                        of: driver.frame,
                        side: driverSide,
                        axis: group.axis
                    )
                    let referenceLength = group.axis == .horizontal
                        ? participant.constraintReference.width
                        : participant.constraintReference.height
                    return SplitLayoutGeometry.additionalBoundarySeparationDegree(
                        initialCoordinate: group.initialCoordinate,
                        currentCoordinate: currentCoordinate,
                        participantCoordinates: group.participantCoordinates,
                        referenceLength: referenceLength
                    )
                }.max() ?? 0
                if degree >= threshold {
                    detachedConnections.insert(connection)
                }
                continue
            }

            if participant.isSuspended {
                detachedConnections.insert(connection)
                continue
            }

            applications.append(ManualResizeApplication(
                identity: identity,
                participant: participant,
                activeAxes: activeAxes,
                targetFrame: target,
                connection: connection
            ))
        }

        guard !applications.isEmpty else {
            if var placement = lockedPlacements[driver.stableIdentity] {
                placement.appliedFrame = driver.frame
                lockedPlacements[driver.stableIdentity] = placement
            }
            inFlightPlacementIDs.subtract(
                Set(session.participants.keys).union([driver.stableIdentity])
            )
            virtualResizeOverlay.hideAll()
            return
        }

        let operationIDs = Set(session.participants.keys).union([driver.stableIdentity])
        inFlightPlacementIDs.formUnion(operationIDs)
        let applicationIDs = Set(applications.map(\.identity))
        for application in applications {
            let rollbackWindow = windowService.refreshed(
                application.participant.window
            ) ?? application.participant.window
            pendingPlacementSnapshots[application.identity] = windowService.snapshot(
                rollbackWindow
            )
        }
        var pendingCompletions = applications.count
        var acceptedWindows: [String: ManagedWindow] = [:]
        var connectionResults: [SplitConnectionKey: Bool] = [:]

        for application in applications {
            applyManualResizeApplication(
                application,
                driver: driver,
                generation: generation,
                attempt: 0
            ) { [weak self] actual, degree, outerEdgesMatch in
                guard let self else { return }
                acceptedWindows[application.identity] = actual
                connectionResults[application.connection] =
                    SplitLayoutGeometry.manualResizeConnectionRemainsValid(
                        boundaryDegree: degree,
                        intrusionTolerance: threshold,
                        outerEdgesMatch: outerEdgesMatch
                    )
                pendingCompletions -= 1
                guard pendingCompletions == 0 else { return }

                if self.interactionGeneration == generation {
                    for identity in applicationIDs {
                        self.pendingPlacementSnapshots.removeValue(forKey: identity)
                    }
                    if var placement = self.lockedPlacements[driver.stableIdentity] {
                        placement.appliedFrame = driver.frame
                        self.lockedPlacements[driver.stableIdentity] = placement
                    }
                    for (identity, window) in acceptedWindows {
                        if var placement = self.lockedPlacements[identity] {
                            placement.appliedFrame = window.frame
                            self.lockedPlacements[identity] = placement
                        }
                    }
                    for (connection, remainsConnected) in connectionResults {
                        if remainsConnected {
                            self.detachedConnections.remove(connection)
                        } else {
                            self.detachedConnections.insert(connection)
                        }
                    }
                    let connectedFollowers = applications.compactMap { application -> ManagedWindow? in
                        guard connectionResults[application.connection] == true else {
                            return nil
                        }
                        return acceptedWindows[application.identity]
                    }
                    for follower in connectedFollowers {
                        self.windowService.raise(follower)
                    }
                    self.windowService.focus(driver)
                }
                self.inFlightPlacementIDs.subtract(operationIDs)
                self.virtualResizeOverlay.hideAll()
            }
        }
    }

    private func applyManualResizeApplication(
        _ application: ManualResizeApplication,
        driver: ManagedWindow,
        generation: Int,
        attempt: Int,
        completion: @escaping (ManagedWindow, CGFloat, Bool) -> Void
    ) {
        let participant = application.participant
        windowService.setFrameAnchoredReliably(
            application.targetFrame,
            sizeConstraintAnchor: boundaryAnchor(
                sides: participant.sides,
                activeAxes: application.activeAxes
            ),
            requiredOuterEdges: participant.zone.requiredOuterEdges,
            for: participant.window.element
        ) { [weak self] _ in
            guard let self,
                  self.interactionGeneration == generation else { return }
            let actualFrame = self.windowService.refreshedFrame(participant.window)
                ?? participant.window.frame
            let actual = participant.window.replacingFrame(actualFrame)
            let boundaryError = self.manualBoundaryError(
                actualFrame: actual.frame,
                participant: participant,
                activeAxes: application.activeAxes,
                driver: driver
            )
            let outerEdgesMatch = self.matchesRequiredOuterEdges(
                actual.frame,
                targetFrame: application.targetFrame,
                requiredEdges: participant.zone.requiredOuterEdges
            )
            if attempt == 0,
               boundaryError > 1 || !outerEdgesMatch {
                self.applyManualResizeApplication(
                    application,
                    driver: driver,
                    generation: generation,
                    attempt: 1,
                    completion: completion
                )
                return
            }

            self.observeConstraint(for: actual, requestedSize: application.targetFrame.size)
            completion(
                actual,
                self.manualBoundaryDegree(
                    actualFrame: actual.frame,
                    participant: participant,
                    activeAxes: application.activeAxes,
                    driver: driver
                ),
                outerEdgesMatch
            )
        }
    }

    private func manualBoundaryError(
        actualFrame: CGRect,
        participant: ManualResizeParticipant,
        activeAxes: Set<SplitAxis>,
        driver: ManagedWindow
    ) -> CGFloat {
        activeAxes.map { axis -> CGFloat in
            guard let participantSide = participant.sides[axis],
                  let driverSide = SplitLayoutGeometry.boundarySide(
                      for: lockedPlacements[driver.stableIdentity]?.zone ?? .maximize,
                      axis: axis
                  ) else { return 0 }
            let participantCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: actualFrame,
                side: participantSide,
                axis: axis
            )
            let driverCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: driver.frame,
                side: driverSide,
                axis: axis
            )
            return abs(participantCoordinate - driverCoordinate)
        }.max() ?? 0
    }

    private func manualBoundaryDegree(
        actualFrame: CGRect,
        participant: ManualResizeParticipant,
        activeAxes: Set<SplitAxis>,
        driver: ManagedWindow
    ) -> CGFloat {
        activeAxes.map { axis -> CGFloat in
            let referenceLength = axis == .horizontal
                ? participant.constraintReference.width
                : participant.constraintReference.height
            return manualBoundaryError(
                actualFrame: actualFrame,
                participant: participant,
                activeAxes: [axis],
                driver: driver
            ) / max(referenceLength, 1)
        }.max() ?? 0
    }

    private func boundaryAnchor(
        sides: [SplitAxis: SplitBoundarySide],
        activeAxes: Set<SplitAxis>
    ) -> CGPoint {
        var anchor = CGPoint(x: 0.5, y: 0.5)
        if activeAxes.contains(.horizontal), let side = sides[.horizontal] {
            anchor.x = side == .nearOrigin ? 0 : 1
        }
        if activeAxes.contains(.vertical), let side = sides[.vertical] {
            anchor.y = side == .nearOrigin ? 0 : 1
        }
        return anchor
    }

    private func adoptDetachedWindowIfNeeded(at point: CGPoint, allowImmediate: Bool) -> Bool {
        guard let source = sourceDragWindow,
              let candidate = windowService.focusedWindow(),
              candidate.pid == source.pid,
              candidate.stableIdentity != source.stableIdentity,
              candidate.stableIdentity != dragWindow?.stableIdentity,
              !windowIDsAtDragStart.contains(candidate.stableIdentity),
              windowService.canMoveAndResize(candidate),
              isLikelyDetachedWindow(candidate, following: point) else {
            detachedCandidateID = nil
            detachedCandidateHitCount = 0
            return false
        }

        if detachedCandidateID == candidate.stableIdentity {
            detachedCandidateHitCount += 1
        } else {
            detachedCandidateID = candidate.stableIdentity
            detachedCandidateHitCount = 1
        }
        guard allowImmediate || detachedCandidateHitCount >= 2 else { return false }

        dragRestoreFrameCandidate = restoreFrames[source.stableIdentity] ?? source.frame
        releaseManualResizeProtection(
            driverIdentity: source.stableIdentity,
            session: manualResizeSession
        )
        pendingDragWindow = candidate
        pendingDragWindowFrame = candidate.frame
        pendingDragMousePoint = point
        pendingGrabRatio = grabRatio(at: point, in: candidate.frame)
        pendingRestoreFrame = nil
        pendingDragStartedInLikelyDragRegion = true
        pendingDragStartedNearResizeEdge = false
        dragWindow = candidate
        isWindowMoveConfirmed = true
        hasWindowActuallyMoved = true
        manualResizeSession = nil
        virtualResizeOverlay.hideAll()
        return true
    }

    private func confirmWindowMove(at currentMousePoint: CGPoint, allowEdgeFallback: Bool = false) -> Bool {
        guard let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame,
              let originalMousePoint = pendingDragMousePoint,
              let currentWindow = windowService.refreshed(originalWindow) else {
            return false
        }

        let windowDelta = CGPoint(
            x: currentWindow.frame.minX - originalFrame.minX,
            y: currentWindow.frame.minY - originalFrame.minY
        )
        let mouseDelta = CGPoint(
            x: currentMousePoint.x - originalMousePoint.x,
            y: currentMousePoint.y - originalMousePoint.y
        )

        let mouseDistance = hypot(mouseDelta.x, mouseDelta.y)
        let windowDistance = hypot(windowDelta.x, windowDelta.y)

        let sizeTolerance: CGFloat = 1.5
        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width) > sizeTolerance
            || abs(currentWindow.frame.height - originalFrame.height) > sizeTolerance
        guard !sizeChanged else { return false }

        if windowDistance >= 2, mouseDistance >= 2 {
            let dot = windowDelta.x * mouseDelta.x + windowDelta.y * mouseDelta.y
            let directionMatches = dot > 0
            let followTolerance = max(18, min(72, mouseDistance * 0.55))
            let closelyFollows = abs(windowDelta.x - mouseDelta.x) <= followTolerance
                && abs(windowDelta.y - mouseDelta.y) <= followTolerance

            if closelyFollows || directionMatches {
                promoteToConfirmedDrag(currentWindow, at: currentMousePoint, windowActuallyMoved: true)
                return true
            }
        }

        if allowEdgeFallback || isNearSnapEdge(currentMousePoint),
           pendingDragStartedInLikelyDragRegion,
           mouseDistance >= 4 {
            let currentIDs = windowService.windowIdentities(forPID: originalWindow.pid)
            guard currentIDs.subtracting(windowIDsAtDragStart).isEmpty else { return false }
            promoteToConfirmedDrag(currentWindow, at: currentMousePoint, windowActuallyMoved: false)
            return true
        }

        return false
    }

    private func promoteToConfirmedDrag(
        _ window: ManagedWindow,
        at mousePoint: CGPoint,
        windowActuallyMoved: Bool
    ) {
        releaseManualResizeProtection(
            driverIdentity: window.stableIdentity,
            session: manualResizeSession
        )
        manualResizeSession = nil
        virtualResizeOverlay.hideAll()
        dragWindow = window
        isWindowMoveConfirmed = true
        guard windowActuallyMoved else { return }
        beginActualWindowMovement(window, at: mousePoint)
    }

    private func detectActualWindowMovementIfNeeded(at mousePoint: CGPoint) {
        guard !hasWindowActuallyMoved,
              let originalFrame = pendingDragWindowFrame,
              let window = dragWindow,
              let current = windowService.refreshed(window) else { return }

        let moved = hypot(
            current.frame.minX - originalFrame.minX,
            current.frame.minY - originalFrame.minY
        ) >= 2
        let sizeChanged = abs(current.frame.width - originalFrame.width) > 1.5
            || abs(current.frame.height - originalFrame.height) > 1.5
        guard moved, !sizeChanged else { return }
        dragWindow = current
        beginActualWindowMovement(current, at: mousePoint)
    }

    private func beginActualWindowMovement(_ window: ManagedWindow, at mousePoint: CGPoint) {
        guard !hasWindowActuallyMoved else { return }
        hasWindowActuallyMoved = true
        lockedPlacements.removeValue(forKey: window.stableIdentity)
        removeConnections(for: window.stableIdentity)

        guard let restoreFrame = pendingRestoreFrame,
              let ratio = pendingGrabRatio else { return }

        let alreadyUsesRestoreSize = abs(window.frame.width - restoreFrame.width) <= 1.5
            && abs(window.frame.height - restoreFrame.height) <= 1.5
        guard settings.restoreSnappedWindowSizeOnMove, !alreadyUsesRestoreSize else {
            restoreFrames.removeValue(forKey: window.stableIdentity)
            pendingRestoreFrame = nil
            dragRestoreFrameCandidate = window.frame
            return
        }

        startSmoothDragRestore(
            window: window,
            targetFrame: restoreFrame,
            grabRatio: ratio,
            mousePoint: mousePoint
        )
    }

    private func startSmoothDragRestore(
        window: ManagedWindow,
        targetFrame: CGRect,
        grabRatio: CGPoint,
        mousePoint: CGPoint
    ) {
        cancelSmoothDragRestore()
        windowService.cancelFrameOperation(for: window.element)
        didStartDragRestore = true
        let startSize = window.frame.size
        let targetSize = targetFrame.size
        let duration: TimeInterval = 0.16
        let startedAt = ProcessInfo.processInfo.systemUptime

        _ = windowService.setFrame(
            anchoredFrame(size: startSize, at: mousePoint, ratio: grabRatio),
            for: window.element
        )

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = min(max(elapsed / duration, 0), 1)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            let size = CGSize(
                width: startSize.width + (targetSize.width - startSize.width) * eased,
                height: startSize.height + (targetSize.height - startSize.height) * eased
            )
            let cursor = NSEvent.mouseLocation
            let frame = self.anchoredFrame(size: size, at: cursor, ratio: grabRatio)
            let frameApplied = self.windowService.setFrame(frame, for: window.element)

            if let refreshed = self.windowService.refreshed(window) {
                self.dragWindow = refreshed
            }

            guard progress >= 1 else { return }
            timer.invalidate()
            self.dragRestoreAnimationTimer = nil
            if frameApplied {
                self.restoreFrames.removeValue(forKey: window.stableIdentity)
            }
        }
        dragRestoreAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishSmoothDragRestore(at mousePoint: CGPoint) {
        guard let window = dragWindow,
              let restoreFrame = dragRestoreFrameCandidate,
              let ratio = pendingGrabRatio,
              didStartDragRestore else {
            cancelSmoothDragRestore()
            return
        }

        cancelSmoothDragRestore()
        let finalFrame = anchoredFrame(size: restoreFrame.size, at: mousePoint, ratio: ratio)
        if windowService.setFrame(finalFrame, for: window.element) {
            restoreFrames.removeValue(forKey: window.stableIdentity)
        }
        dragWindow = windowService.refreshed(window) ?? window
    }

    private func cancelSmoothDragRestore() {
        dragRestoreAnimationTimer?.invalidate()
        dragRestoreAnimationTimer = nil
    }

    private func anchoredFrame(size: CGSize, at mousePoint: CGPoint, ratio: CGPoint) -> CGRect {
        var frame = CGRect(
            x: mousePoint.x - size.width * ratio.x,
            y: mousePoint.y - size.height * ratio.y,
            width: size.width,
            height: size.height
        )
        guard let visibleFrame = screenOwning(mousePoint)?.visibleFrame else { return frame }

        let minimumVisibleWidth = min(max(frame.width * 0.15, 96), 160)
        if frame.maxX < visibleFrame.minX + minimumVisibleWidth {
            frame.origin.x += visibleFrame.minX + minimumVisibleWidth - frame.maxX
        } else if frame.minX > visibleFrame.maxX - minimumVisibleWidth {
            frame.origin.x -= frame.minX - (visibleFrame.maxX - minimumVisibleWidth)
        }

        let titleBarTop = min(max(frame.maxY, visibleFrame.minY + 36), visibleFrame.maxY)
        frame.origin.y += titleBarTop - frame.maxY
        return frame
    }

    private func grabRatio(at point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 1) }
        return CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    private func isLikelyDetachedWindow(_ window: ManagedWindow, following point: CGPoint) -> Bool {
        let horizontalMargin: CGFloat = 28
        let topBandHeight = min(120, max(48, window.frame.height * 0.18))
        let titleBand = CGRect(
            x: window.frame.minX - horizontalMargin,
            y: window.frame.maxY - topBandHeight - 20,
            width: window.frame.width + horizontalMargin * 2,
            height: topBandHeight + 40
        )
        return titleBand.contains(point)
    }

    private func handleDrag(at point: CGPoint) {
        picker.hide()
        guard dragWindow != nil, isWindowMoveConfirmed else { return }

        guard let target = snapTarget(at: point, shouldUpdateDisplayTransition: true),
              let screen = screen(withDisplayID: target.displayID) else {
            resetSideDwellState()
            if activeTarget != nil {
                activeTarget = nil
                overlay.hide()
            }
            return
        }

        updateSideDwell(for: target, at: point, on: screen)

        guard activeTarget != target else { return }
        activeTarget = target
        overlay.show(
            frame: predictedSnapFrame(
                for: target.zone,
                on: screen,
                window: dragWindow
            ),
            from: point
        )
    }

    private func handleDrop(at point: CGPoint) {
        defer {
            overlay.hide()
            resetDragState()
        }

        let adoptedDetachedWindow = adoptDetachedWindowIfNeeded(at: point, allowImmediate: true)
        if dragWindow == nil, !adoptedDetachedWindow {
            _ = confirmWindowMove(at: point, allowEdgeFallback: true)
        }
        guard let window = dragWindow else { return }

        let target = activeTarget
            ?? snapTarget(at: point, shouldUpdateDisplayTransition: false)

        guard let target,
              let screen = screen(withDisplayID: target.displayID) else {
            finishSmoothDragRestore(at: point)
            return
        }

        cancelSmoothDragRestore()
        let currentWindow = windowService.refreshed(window) ?? window
        activeSession = nil
        snap(currentWindow, to: target.zone, on: screen, continueAssist: true)
    }

    private func snap(
        _ window: ManagedWindow,
        to zone: SnapZone,
        on screen: NSScreen,
        continueAssist: Bool,
        activateAfterInitialPlacement: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let pendingSnapshot = windowService.snapshot(window)
        let wasKnownSnappedWindow = restoreFrames[window.stableIdentity] != nil
        let pendingRestoreCandidate: CGRect
        if let dragRestoreFrameCandidate,
           dragWindow?.stableIdentity == window.stableIdentity {
            pendingRestoreCandidate = dragRestoreFrameCandidate
        } else if wasKnownSnappedWindow,
                  let stored = restoreFrames[window.stableIdentity] {
            pendingRestoreCandidate = stored
        } else {
            pendingRestoreCandidate = pendingSnapshot.frame
        }
        let operationGeneration = interactionGeneration
        pendingPlacementSnapshots[window.stableIdentity] = pendingSnapshot
        let targetFrame = resolvedSnapFrame(
            for: zone,
            on: screen,
            excluding: window.stableIdentity
        )

        let applySnap = { [weak self] in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            let afterInitialFrameAttempt: (() -> Void)?
            if activateAfterInitialPlacement {
                afterInitialFrameAttempt = { [weak self] in
                    guard let self,
                          self.interactionGeneration == operationGeneration else { return }
                    self.windowService.focus(window)
                }
            } else {
                afterInitialFrameAttempt = nil
            }

            self.windowService.setFrameAnchoredReliably(
                targetFrame,
                sizeConstraintAnchor: zone.sizeConstraintAnchor,
                requiredOuterEdges: zone.requiredOuterEdges,
                for: window.element,
                afterInitialFrameAttempt: afterInitialFrameAttempt
            ) { [weak self] succeeded in
                guard let self,
                      self.interactionGeneration == operationGeneration else { return }

                let appliedWindow = self.windowService.refreshed(window)
                let requiredEdgesAreCorrect = appliedWindow.map {
                    self.matchesRequiredOuterEdges(
                        $0.frame,
                        targetFrame: targetFrame,
                        requiredEdges: zone.requiredOuterEdges
                    )
                } ?? false
                guard succeeded && requiredEdgesAreCorrect else {
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    self.rollbackFailedPlacement(pendingSnapshot) {
                        completion?(false)
                    }
                    return
                }
                let refreshedWindow = appliedWindow ?? window
                self.observeConstraint(for: refreshedWindow, requestedSize: targetFrame.size)
                switch self.initialSplitDisposition(
                    for: refreshedWindow,
                    originalSize: pendingSnapshot.frame.size,
                    requestedFrame: targetFrame,
                    zone: zone,
                    on: screen
                ) {
                case .accept:
                    self.finalizeSuccessfulSnap(
                        refreshedWindow,
                        zone: zone,
                        on: screen,
                        snapshots: [pendingSnapshot],
                        restoreFrame: pendingRestoreCandidate,
                        continueAssist: continueAssist,
                        completion: completion
                    )

                case .reflow(let plan):
                    self.performInitialReflow(
                        plan,
                        candidate: refreshedWindow,
                        candidateSnapshot: pendingSnapshot,
                        restoreFrame: pendingRestoreCandidate,
                        zone: zone,
                        on: screen,
                        continueAssist: continueAssist,
                        operationGeneration: operationGeneration,
                        completion: completion
                    )

                case .reject:
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    self.rollbackFailedPlacement(pendingSnapshot) {
                        completion?(false)
                    }
                }
            }
        }

        if window.isFullscreen {
            guard windowService.setFullscreen(false, for: window.element) else {
                pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                overlay.hide()
                completion?(false)
                return
            }
            windowService.waitForFullscreenState(false, for: window.element) { [weak self] succeeded in
                guard let self,
                      self.interactionGeneration == operationGeneration else { return }
                if succeeded {
                    applySnap()
                } else {
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    _ = self.windowService.setFullscreen(true, for: window.element)
                    self.overlay.hide()
                    completion?(false)
                }
            }
        } else {
            applySnap()
        }
    }

    private func initialSplitDisposition(
        for candidate: ManagedWindow,
        originalSize: CGSize,
        requestedFrame: CGRect,
        zone: SnapZone,
        on screen: NSScreen
    ) -> InitialSplitDisposition {
        let axes = SplitLayoutGeometry.splitAxes(for: zone)
        guard !axes.isEmpty else { return .accept }

        let reference = constraintReference(
            stableIdentity: candidate.stableIdentity,
            currentSize: originalSize,
            zone: zone,
            on: screen
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var failingAxes: Set<SplitAxis> = []

        if axes.contains(.horizontal),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: requestedFrame.width,
               acceptedLength: candidate.frame.width,
               referenceLength: reference.width
           ) > tolerance {
            failingAxes.insert(.horizontal)
        }
        if axes.contains(.vertical),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: requestedFrame.height,
               acceptedLength: candidate.frame.height,
               referenceLength: reference.height
           ) > tolerance {
            failingAxes.insert(.vertical)
        }
        guard !failingAxes.isEmpty else { return .accept }
        // A two-axis initial reflow would need to reshape the diagonal window in
        // both dimensions at once. Keep the existing grid intact unless the
        // operation can be represented by one complete boundary transaction.
        guard failingAxes.count == 1 else { return .reject }

        var desiredSize = candidate.frame.size
        if failingAxes.contains(.horizontal) {
            desiredSize.width = max(desiredSize.width, reference.width)
        }
        if failingAxes.contains(.vertical) {
            desiredSize.height = max(desiredSize.height, reference.height)
        }
        guard desiredSize.width <= screen.visibleFrame.width + 1,
              desiredSize.height <= screen.visibleFrame.height + 1 else {
            return .reject
        }

        let candidateTarget = SplitLayoutGeometry.anchoredFrame(
            around: requestedFrame,
            size: desiredSize,
            anchor: zone.sizeConstraintAnchor
        )
        guard let followers = makeInitialReflowFollowers(
            candidateIdentity: candidate.stableIdentity,
            candidateZone: zone,
            candidateStartFrame: requestedFrame,
            candidateFrame: candidateTarget,
            axes: failingAxes,
            on: screen
        ) else {
            return .reject
        }
        guard !followers.isEmpty else {
            return .accept
        }
        return .reflow(InitialReflowPlan(
            axes: failingAxes,
            candidateStartFrame: requestedFrame,
            candidateTarget: candidateTarget
        ))
    }

    private func makeInitialReflowFollowers(
        candidateIdentity: String,
        candidateZone: SnapZone,
        candidateStartFrame: CGRect,
        candidateFrame: CGRect,
        axes: Set<SplitAxis>,
        on screen: NSScreen
    ) -> [InitialReflowFollower]? {
        guard let currentDisplayID = displayID(for: screen) else { return nil }
        let windows = windowService.visibleWindows()
        let windowsByIdentity = Dictionary(
            windows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var followersByIdentity: [String: InitialReflowFollower] = [:]

        for axis in axes {
            guard let candidateSide = SplitLayoutGeometry.boundarySide(
                for: candidateZone,
                axis: axis
            ) else { return nil }
            let candidateBands = SplitLayoutGeometry.perpendicularBands(
                for: candidateZone,
                axis: axis
            )
            let initialCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: candidateStartFrame,
                side: candidateSide,
                axis: axis
            )
            let currentCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                of: candidateFrame,
                side: candidateSide,
                axis: axis
            )

            for band in [SplitPerpendicularBand.first, .second] {
                let members = lockedPlacements.compactMap { identity, placement
                    -> (String, LockedPlacement, ManagedWindow, SplitBoundarySide)? in
                    guard identity != candidateIdentity,
                          placement.displayID == currentDisplayID,
                          SplitLayoutGeometry.perpendicularBands(
                              for: placement.zone,
                              axis: axis
                          ).contains(band),
                          let side = SplitLayoutGeometry.boundarySide(
                              for: placement.zone,
                              axis: axis
                          ),
                          let window = windowsByIdentity[identity] else { return nil }
                    return (identity, placement, window, side)
                }
                guard !members.isEmpty else { continue }

                var occupiedSides = Set(members.map { $0.3 })
                if candidateBands.contains(band) {
                    occupiedSides.insert(candidateSide)
                }
                guard occupiedSides.count == 2 else { continue }
                let coordinates = members.map {
                    SplitLayoutGeometry.boundaryCoordinate(
                        of: $0.2.frame,
                        side: $0.3,
                        axis: axis
                    )
                }
                guard SplitLayoutGeometry.hasReachedBoundary(
                    initialCoordinate: initialCoordinate,
                    currentCoordinate: currentCoordinate,
                    participantCoordinates: coordinates
                ) else { continue }

                for (identity, placement, follower, side) in members {
                    let target = SplitLayoutGeometry.frame(
                        follower.frame,
                        meetingBoundary: currentCoordinate,
                        side: side,
                        axis: axis
                    )
                    let reference = constraintReference(
                        for: follower,
                        zone: placement.zone,
                        on: screen
                    )
                    let targetLength = axis == .horizontal ? target.width : target.height
                    let referenceLength = axis == .horizontal ? reference.width : reference.height
                    guard target.width > 0,
                          target.height > 0,
                          SplitLayoutGeometry.compressionRatio(
                              targetLength: targetLength,
                              referenceLength: referenceLength
                          ) <= tolerance else {
                        return nil
                    }
                    followersByIdentity[identity] = InitialReflowFollower(
                        window: follower,
                        zone: placement.zone,
                        axis: axis,
                        side: side,
                        originalFrame: follower.frame,
                        targetFrame: target,
                        constraintReference: reference
                    )
                }
            }
        }
        return Array(followersByIdentity.values)
    }

    private func performInitialReflow(
        _ plan: InitialReflowPlan,
        candidate: ManagedWindow,
        candidateSnapshot: WindowSnapshot,
        restoreFrame: CGRect,
        zone: SnapZone,
        on screen: NSScreen,
        continueAssist: Bool,
        operationGeneration: Int,
        completion: ((Bool) -> Void)?
    ) {
        windowService.setFrameAnchoredReliably(
            plan.candidateTarget,
            sizeConstraintAnchor: zone.sizeConstraintAnchor,
            requiredOuterEdges: zone.requiredOuterEdges,
            for: candidate.element
        ) { [weak self] _ in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            guard let appliedCandidate = self.windowService.refreshed(candidate),
                  self.matchesRequiredOuterEdges(
                      appliedCandidate.frame,
                      targetFrame: plan.candidateTarget,
                      requiredEdges: zone.requiredOuterEdges
                  ) else {
                self.rollbackTransaction([candidateSnapshot], completion: completion)
                return
            }
            self.observeConstraint(for: appliedCandidate, requestedSize: plan.candidateTarget.size)

            guard let followers = self.makeInitialReflowFollowers(
                candidateIdentity: appliedCandidate.stableIdentity,
                candidateZone: zone,
                candidateStartFrame: plan.candidateStartFrame,
                candidateFrame: appliedCandidate.frame,
                axes: plan.axes,
                on: screen
            ), !followers.isEmpty else {
                self.rollbackTransaction([candidateSnapshot], completion: completion)
                return
            }

            let followerSnapshots = followers.map { self.windowService.snapshot($0.window) }
            for snapshot in followerSnapshots {
                self.pendingPlacementSnapshots[snapshot.stableIdentity] = snapshot
            }
            self.virtualResizeOverlay.update(
                items: followers.map { follower in
                    VirtualResizeItem(
                        stableIdentity: follower.window.stableIdentity,
                        originalFrame: follower.originalFrame,
                        targetFrame: follower.targetFrame,
                        appIcon: follower.window.appIcon
                    )
                },
                driverFrame: appliedCandidate.frame,
                screenFrame: screen.visibleFrame
            )

            var pending = followers.count
            var allAccepted = true
            var acceptedFollowers: [String: ManagedWindow] = [:]
            let tolerance = CGFloat(self.settings.layoutIntrusionTolerance)

            for follower in followers {
                self.windowService.setFrameAnchoredReliably(
                    follower.targetFrame,
                    sizeConstraintAnchor: self.boundaryAnchor(
                        sides: [follower.axis: follower.side],
                        activeAxes: [follower.axis]
                    ),
                    requiredOuterEdges: follower.zone.requiredOuterEdges,
                    for: follower.window.element
                ) { [weak self] _ in
                    guard let self else { return }
                    defer {
                        pending -= 1
                        if pending == 0 {
                            self.virtualResizeOverlay.hideAll()
                            if self.interactionGeneration == operationGeneration,
                               allAccepted {
                                for accepted in acceptedFollowers.values {
                                    if var placement = self.lockedPlacements[accepted.stableIdentity] {
                                        placement.appliedFrame = accepted.frame
                                        self.lockedPlacements[accepted.stableIdentity] = placement
                                    }
                                }
                                self.finalizeSuccessfulSnap(
                                    appliedCandidate,
                                    zone: zone,
                                    on: screen,
                                    snapshots: [candidateSnapshot] + followerSnapshots,
                                    restoreFrame: restoreFrame,
                                    continueAssist: continueAssist,
                                    completion: completion
                                )
                            } else {
                                self.rollbackTransaction(
                                    [candidateSnapshot] + followerSnapshots,
                                    completion: completion
                                )
                            }
                        }
                    }

                    guard self.interactionGeneration == operationGeneration else {
                        allAccepted = false
                        return
                    }
                    let actual = self.windowService.refreshed(follower.window) ?? follower.window
                    self.observeConstraint(for: actual, requestedSize: follower.targetFrame.size)
                    guard let candidateSide = SplitLayoutGeometry.boundarySide(
                        for: zone,
                        axis: follower.axis
                    ) else {
                        allAccepted = false
                        return
                    }
                    let candidateCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                        of: appliedCandidate.frame,
                        side: candidateSide,
                        axis: follower.axis
                    )
                    let followerCoordinate = SplitLayoutGeometry.boundaryCoordinate(
                        of: actual.frame,
                        side: follower.side,
                        axis: follower.axis
                    )
                    let referenceLength = follower.axis == .horizontal
                        ? follower.constraintReference.width
                        : follower.constraintReference.height
                    let degree = abs(candidateCoordinate - followerCoordinate)
                        / max(referenceLength, 1)
                    let outerEdgesMatch = self.matchesRequiredOuterEdges(
                        actual.frame,
                        targetFrame: follower.targetFrame,
                        requiredEdges: follower.zone.requiredOuterEdges
                    )
                    allAccepted = allAccepted && degree <= tolerance && outerEdgesMatch
                    acceptedFollowers[actual.stableIdentity] = actual
                }
            }
        }
    }

    private func finalizeSuccessfulSnap(
        _ window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen,
        snapshots: [WindowSnapshot],
        restoreFrame: CGRect,
        continueAssist: Bool,
        completion: ((Bool) -> Void)?
    ) {
        for snapshot in snapshots {
            pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        }
        commitSnapshots(snapshots)
        restoreFrames[window.stableIdentity] = restoreFrame
        registerLock(for: window, zone: zone, on: screen)
        raiseSnapGroup(withMainWindow: window, on: screen)
        advanceAssist(
            with: window,
            justPlacedZone: zone,
            on: screen,
            continueAssist: continueAssist
        )
        refreshResizeHandles()
        completion?(true)
    }

    private func resolvedUserWindowAtMouseUp(
        at point: CGPoint,
        visibleWindows: [ManagedWindow]
    ) -> ManagedWindow? {
        if let pendingDragWindow,
           let current = visibleWindows.first(where: {
               $0.stableIdentity == pendingDragWindow.stableIdentity
           }),
           current.frame.contains(point),
           windowService.canMoveAndResize(current) {
            return current
        }
        return visibleWindows.first {
            $0.frame.contains(point) && windowService.canMoveAndResize($0)
        }
    }

    private func scheduleConnectedGroupRaiseForPlainClick(at point: CGPoint) {
        invalidatePendingGroupRaise()
        guard isEnabled,
              settings.linkedResizeEnabled,
              settings.raiseConnectedWindowsOnClick,
              !isApplicationUIVisible,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending else { return }

        groupRaiseGeneration &+= 1
        scheduleConnectedGroupRaiseEvaluation(
            at: point,
            clickedIdentity: nil,
            completedAttempts: 0,
            generation: groupRaiseGeneration,
            delay: groupRaiseSettleDelay
        )
    }

    private func scheduleConnectedGroupRaiseEvaluation(
        at point: CGPoint,
        clickedIdentity: String?,
        completedAttempts: Int,
        generation: Int,
        delay: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.groupRaiseGeneration == generation else { return }
            self.pendingGroupRaiseWorkItem = nil
            self.evaluateConnectedGroupRaise(
                at: point,
                clickedIdentity: clickedIdentity,
                completedAttempts: completedAttempts,
                generation: generation
            )
        }
        pendingGroupRaiseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func evaluateConnectedGroupRaise(
        at point: CGPoint,
        clickedIdentity: String?,
        completedAttempts: Int,
        generation: Int
    ) {
        guard groupRaiseGeneration == generation,
              isEnabled,
              settings.linkedResizeEnabled,
              settings.raiseConnectedWindowsOnClick,
              !isApplicationUIVisible,
              handleResizeSession == nil,
              !isHandleResizeFinalizing,
              activeSession == nil,
              !isAssistPlacementPending else { return }

        let visibleWindows = windowService.visibleWindows()
        let clickedWindow: ManagedWindow?
        if let clickedIdentity {
            clickedWindow = visibleWindows.first {
                $0.stableIdentity == clickedIdentity
            }
        } else {
            clickedWindow = resolvedUserWindowAtMouseUp(
                at: point,
                visibleWindows: visibleWindows
            )
        }
        guard let clickedWindow,
              let groupWindows = connectedSnapGroupWindows(
                  for: clickedWindow,
                  visibleWindows: visibleWindows
              ) else { return }

        if connectedGroupIsAlreadyFrontmost(
            groupWindows,
            within: visibleWindows
        ) {
            if completedAttempts > 0 {
                refreshResizeHandleOcclusion(force: true)
            }
            return
        }

        guard completedAttempts < maximumGroupRaiseAttempts else {
            refreshResizeHandleOcclusion(force: true)
            return
        }
        _ = raiseWindows(groupWindows, withMainWindow: clickedWindow)
        scheduleConnectedGroupRaiseEvaluation(
            at: point,
            clickedIdentity: clickedWindow.stableIdentity,
            completedAttempts: completedAttempts + 1,
            generation: generation,
            delay: groupRaiseVerificationDelay
        )
    }

    private func connectedSnapGroupWindows(
        for clickedWindow: ManagedWindow,
        visibleWindows: [ManagedWindow]
    ) -> [ManagedWindow]? {
        guard let placement = lockedPlacements[clickedWindow.stableIdentity],
              let screen = screen(withDisplayID: placement.displayID),
              let currentDisplayID = displayID(for: screen) else { return nil }

        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let placements = lockedPlacements.compactMap { identity, placement
            -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  let currentWindow = windowsByIdentity[identity] else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: currentWindow.frame
            )
        }
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements,
            detachedConnections: detachedConnections
        )
        let groupIDs = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: clickedWindow.stableIdentity,
            handles: handles
        )
        guard groupIDs.count >= 2 else { return nil }
        return visibleWindows.filter { groupIDs.contains($0.stableIdentity) }
    }

    private func connectedGroupIsAlreadyFrontmost(
        _ groupWindows: [ManagedWindow],
        within visibleWindows: [ManagedWindow]
    ) -> Bool {
        let groupIDs = Set(groupWindows.map(\.stableIdentity))
        return SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: groupIDs,
            orderedWindows: visibleWindows.map {
                SplitZOrderWindow(
                    stableIdentity: $0.stableIdentity,
                    frame: $0.frame
                )
            }
        )
    }

    private func invalidatePendingGroupRaise() {
        groupRaiseGeneration &+= 1
        pendingGroupRaiseWorkItem?.cancel()
        pendingGroupRaiseWorkItem = nil
    }

    @discardableResult
    private func raiseWindows(
        _ windows: [ManagedWindow],
        withMainWindow mainWindow: ManagedWindow
    ) -> Bool {
        var seen = Set<String>()
        let uniqueWindows = windows.filter {
            seen.insert($0.stableIdentity).inserted
        }
        let followers = uniqueWindows.filter {
            $0.stableIdentity != mainWindow.stableIdentity
        }
        var didRaiseAnyWindow = false
        for follower in followers.reversed() {
            didRaiseAnyWindow = windowService.raise(follower) || didRaiseAnyWindow
        }
        didRaiseAnyWindow = windowService.raise(mainWindow) || didRaiseAnyWindow
        return didRaiseAnyWindow
    }

    private func raiseSnapGroup(
        withMainWindow mainWindow: ManagedWindow,
        on screen: NSScreen,
        requiresConnectedPeer: Bool = false
    ) {
        guard let currentDisplayID = displayID(for: screen) else { return }
        let visibleWindows = windowService.visibleWindows()
        let windowsByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let placements = lockedPlacements.compactMap { identity, placement
            -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  let currentWindow = windowsByIdentity[identity] else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: currentWindow.frame
            )
        }
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements,
            detachedConnections: detachedConnections
        )

        let groupIDs = SplitLayoutGeometry.connectedParticipantIDs(
            startingWith: mainWindow.stableIdentity,
            handles: handles
        )

        if requiresConnectedPeer, groupIDs.count < 2 { return }
        let groupWindows = visibleWindows.filter {
            groupIDs.contains($0.stableIdentity)
        }
        raiseWindows(groupWindows, withMainWindow: mainWindow)
    }

    private func rollbackTransaction(
        _ snapshots: [WindowSnapshot],
        completion: ((Bool) -> Void)?
    ) {
        virtualResizeOverlay.hideAll()
        guard !snapshots.isEmpty else {
            completion?(false)
            return
        }
        for snapshot in snapshots {
            pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        }
        var pending = snapshots.count
        for snapshot in snapshots {
            windowService.restore(snapshot) { _ in
                pending -= 1
                if pending == 0 {
                    completion?(false)
                }
            }
        }
    }

    private func matchesRequiredOuterEdges(
        _ frame: CGRect,
        targetFrame: CGRect,
        requiredEdges: SnapOuterEdges
    ) -> Bool {
        let tolerance: CGFloat = 1

        if requiredEdges.contains(.left),
           abs(frame.minX - targetFrame.minX) > tolerance {
            return false
        }
        if requiredEdges.contains(.right),
           abs(frame.maxX - targetFrame.maxX) > tolerance {
            return false
        }
        if requiredEdges.contains(.top),
           abs(frame.maxY - targetFrame.maxY) > tolerance {
            return false
        }
        if requiredEdges.contains(.bottom),
           abs(frame.minY - targetFrame.minY) > tolerance {
            return false
        }
        return true
    }

    private func rollbackFailedPlacement(
        _ snapshot: WindowSnapshot,
        completion: (() -> Void)? = nil
    ) {
        pendingPlacementSnapshots.removeValue(forKey: snapshot.stableIdentity)
        windowService.restore(snapshot) { _ in
            completion?()
        }
    }

    private func commitSnapshots(_ snapshots: [WindowSnapshot]) {
        guard !snapshots.isEmpty else { return }
        snapshotTransactions.append(SnapshotTransaction(snapshots: snapshots))
        if snapshotTransactions.count > 30 {
            snapshotTransactions.removeFirst(snapshotTransactions.count - 30)
        }
    }

    private func advanceAssist(with placedWindow: ManagedWindow, justPlacedZone zone: SnapZone, on screen: NSScreen, continueAssist: Bool) {
        guard continueAssist, zone != .maximize else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }

        if activeSession == nil {
            activeSession = makeSession(startingWith: zone, window: placedWindow, screen: screen)
        } else {
            activeSession?.occupy(zone, stableIdentity: placedWindow.stableIdentity)
        }

        guard let session = activeSession else { return }
        let remaining = session.remainingZones
        guard !remaining.isEmpty else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }

        let candidates = windowService.visibleWindows(excludingStableIDs: session.occupiedStableIDs)
        guard !candidates.isEmpty else {
            activeSession = nil
            stopEscapeMonitoring()
            picker.hide()
            return
        }
        startEscapeMonitoring()
        let zoneFrames = Dictionary(
            uniqueKeysWithValues: remaining.map { remainingZone in
                let presentationFrame = candidates
                    .map { predictedSnapFrame(for: remainingZone, on: screen, window: $0) }
                    .max { lhs, rhs in
                        lhs.width * lhs.height < rhs.width * rhs.height
                    } ?? resolvedSnapFrame(for: remainingZone, on: screen)
                let nominalFrame = remainingZone.frame(in: screen)
                let clippedPresentation = presentationFrame.intersection(nominalFrame)
                return (
                    remainingZone,
                    clippedPresentation.isNull ? nominalFrame : clippedPresentation
                )
            }
        )
        picker.show(
            windows: candidates,
            zoneFrames: zoneFrames,
            previewProvider: { [weak self] windowID in
                guard let self, self.settings.windowPreviewsEnabled else { return nil }
                return self.windowService.previewCGImage(for: windowID)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.activeSession = nil
                self.stopEscapeMonitoring()
                self.refreshResizeHandles()
            }
        ) { [weak self] selected, targetZone in
            guard let self else { return }
            self.stopEscapeMonitoring()
            guard let current = self.windowService.refreshed(selected),
                  current.stableIdentity == selected.stableIdentity,
                  self.windowService.canMoveAndResize(current) else {
                self.cancelAssist()
                return
            }

            self.isAssistPlacementPending = true
            let selectionGeneration = self.interactionGeneration
            self.windowService.waitForPlacementReadiness(
                current,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return self.isAssistPlacementPending
                        && self.interactionGeneration == selectionGeneration
                }
            ) { [weak self] readyWindow in
                guard let self,
                      self.interactionGeneration == selectionGeneration else { return }
                guard let readyWindow,
                      readyWindow.stableIdentity == selected.stableIdentity else {
                    self.isAssistPlacementPending = false
                    self.activeSession = nil
                    self.picker.hide()
                    self.refreshResizeHandles()
                    return
                }

                self.activeSession = session
                self.snap(
                    readyWindow,
                    to: targetZone,
                    on: screen,
                    continueAssist: true,
                    activateAfterInitialPlacement: true
                ) { [weak self] succeeded in
                    guard let self else { return }
                    self.isAssistPlacementPending = false
                    if !succeeded {
                        self.activeSession = nil
                        self.picker.hide()
                        self.refreshResizeHandles()
                    }
                }
            }
        }
    }

    private func makeSession(startingWith zone: SnapZone, window: ManagedWindow, screen: NSScreen) -> LayoutSession {
        let currentLocks = activeLocks(for: screen, validZones: SnapZone.allCases)
        let layoutZones = layoutZones(startingWith: zone, activeLocks: currentLocks)
        guard !layoutZones.isEmpty else {
            return LayoutSession(layoutZones: [], occupiedZones: [:])
        }

        var occupied: [SnapZone: String] = [:]
        for placement in currentLocks where layoutZones.contains(placement.zone) {
            occupied[placement.zone] = placement.stableIdentity
        }

        occupied[zone] = window.stableIdentity
        return LayoutSession(layoutZones: layoutZones, occupiedZones: occupied)
    }

    private func layoutZones(
        startingWith zone: SnapZone,
        activeLocks: [LockedPlacement]
    ) -> [SnapZone] {
        switch zone {
        case .leftHalf:
            let rightQuarterLocks = Set(
                activeLocks
                    .filter { [.topRight, .bottomRight].contains($0.zone) }
                    .map(\.zone)
            )
            if !rightQuarterLocks.isEmpty {
                return [.leftHalf, .topRight, .bottomRight]
            }
            return [.leftHalf, .rightHalf]

        case .rightHalf:
            let leftQuarterLocks = Set(
                activeLocks
                    .filter { [.topLeft, .bottomLeft].contains($0.zone) }
                    .map(\.zone)
            )
            if !leftQuarterLocks.isEmpty {
                return [.topLeft, .bottomLeft, .rightHalf]
            }
            return [.leftHalf, .rightHalf]

        case .topHalf:
            let lowerLocks = activeLocks.filter {
                [.bottomLeft, .bottomRight].contains($0.zone)
            }
            return lowerLocks.isEmpty
                ? [.topHalf, .bottomHalf]
                : [.topHalf, .bottomLeft, .bottomRight]

        case .bottomHalf:
            let upperLocks = activeLocks.filter {
                [.topLeft, .topRight].contains($0.zone)
            }
            return upperLocks.isEmpty
                ? [.topHalf, .bottomHalf]
                : [.topLeft, .topRight, .bottomHalf]

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            if let oppositeHalf = horizontalHalfLockCompatible(
                with: zone,
                activeLocks: activeLocks
            ) {
                return [oppositeHalf, zone, zone.verticalSibling]
            }

            if let verticalLayout = verticalHalfLayoutCompatible(
                with: zone,
                activeLocks: activeLocks
            ) {
                return verticalLayout
            }

            return [.topLeft, .topRight, .bottomLeft, .bottomRight]

        case .maximize:
            return []
        }
    }

    private func horizontalHalfLockCompatible(
        with zone: SnapZone,
        activeLocks: [LockedPlacement]
    ) -> SnapZone? {
        switch zone {
        case .topLeft, .bottomLeft:
            return activeLocks.first { $0.zone == .rightHalf }?.zone
        case .topRight, .bottomRight:
            return activeLocks.first { $0.zone == .leftHalf }?.zone
        default:
            return nil
        }
    }

    private func verticalHalfLayoutCompatible(
        with zone: SnapZone,
        activeLocks: [LockedPlacement]
    ) -> [SnapZone]? {
        switch zone {
        case .topLeft, .topRight:
            guard activeLocks.contains(where: { $0.zone == .bottomHalf }) else { return nil }
            return [.topLeft, .topRight, .bottomHalf]

        case .bottomLeft, .bottomRight:
            guard activeLocks.contains(where: { $0.zone == .topHalf }) else { return nil }
            return [.topHalf, .bottomLeft, .bottomRight]

        default:
            return nil
        }
    }

    private func resolvedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        excluding excludedIdentity: String? = nil
    ) -> CGRect {
        guard let currentDisplayID = displayID(for: screen) else {
            return zone.frame(in: screen)
        }
        let visibleWindows = windowService.visibleWindows()
        let framesByIdentity = Dictionary(
            visibleWindows.map { ($0.stableIdentity, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        let geometries = lockedPlacements.compactMap { identity, placement -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  let frame = framesByIdentity[identity] else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: frame
            )
        }
        return SplitLayoutGeometry.resolvedFrame(
            for: zone,
            in: screen.visibleFrame,
            placements: geometries,
            excluding: excludedIdentity
        )
    }

    private func predictedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        window: ManagedWindow?
    ) -> CGRect {
        let resolved = recordedSnapFrame(
            for: zone,
            on: screen,
            excluding: window?.stableIdentity
        )
        guard let window else { return resolved }
        let axes = SplitLayoutGeometry.splitAxes(for: zone)
        guard !axes.isEmpty else { return resolved }

        let reference = constraintReference(
            for: window,
            zone: zone,
            on: screen
        )
        let tolerance = CGFloat(settings.layoutIntrusionTolerance)
        var size = resolved.size
        if axes.contains(.horizontal),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: resolved.width,
               acceptedLength: resolved.width,
               referenceLength: reference.width
           ) > tolerance {
            size.width = min(max(size.width, reference.width), screen.visibleFrame.width)
        }
        if axes.contains(.vertical),
           SplitLayoutGeometry.invasionRatio(
               requestedLength: resolved.height,
               acceptedLength: resolved.height,
               referenceLength: reference.height
           ) > tolerance {
            size.height = min(max(size.height, reference.height), screen.visibleFrame.height)
        }
        return SplitLayoutGeometry.anchoredFrame(
            around: resolved,
            size: size,
            anchor: zone.sizeConstraintAnchor
        )
    }

    private func recordedSnapFrame(
        for zone: SnapZone,
        on screen: NSScreen,
        excluding excludedIdentity: String? = nil
    ) -> CGRect {
        guard let currentDisplayID = displayID(for: screen) else {
            return zone.frame(in: screen)
        }
        let geometries = lockedPlacements.compactMap { identity, placement
            -> SplitPlacementGeometry? in
            guard placement.displayID == currentDisplayID,
                  identity != excludedIdentity else { return nil }
            return SplitPlacementGeometry(
                stableIdentity: identity,
                zone: placement.zone,
                frame: placement.appliedFrame
            )
        }
        return SplitLayoutGeometry.resolvedFrame(
            for: zone,
            in: screen.visibleFrame,
            placements: geometries,
            excluding: excludedIdentity
        )
    }

    private func constraintReference(
        for window: ManagedWindow,
        zone: SnapZone,
        on screen: NSScreen
    ) -> CGSize {
        constraintReference(
            stableIdentity: window.stableIdentity,
            currentSize: window.frame.size,
            zone: zone,
            on: screen
        )
    }

    private func constraintReference(
        stableIdentity: String,
        currentSize: CGSize,
        zone: SnapZone,
        on screen: NSScreen
    ) -> CGSize {
        let nominal = zone.frame(in: screen).size
        return constraintHints[stableIdentity, default: WindowConstraintHint()]
            .referenceSize(current: currentSize, nominal: nominal)
    }

    private func observeConstraint(for window: ManagedWindow, requestedSize: CGSize) {
        var hint = constraintHints[window.stableIdentity] ?? WindowConstraintHint()
        hint.observe(requested: requestedSize, accepted: window.frame.size)
        constraintHints[window.stableIdentity] = hint
    }

    private func activeLocks(for screen: NSScreen, validZones: [SnapZone]) -> [LockedPlacement] {
        guard let currentDisplayID = displayID(for: screen) else { return [] }
        let windows = windowService.visibleWindows()
        var windowByID: [String: ManagedWindow] = [:]
        for window in windows { windowByID[window.stableIdentity] = window }

        var matches: [LockedPlacement] = []
        var invalidLocks: [String] = []
        var closedWindows: [String] = []

        for (identity, placement) in lockedPlacements {
            guard placement.displayID == currentDisplayID else { continue }

            if let window = windowByID[identity] {
                if inFlightPlacementIDs.contains(identity) {
                    if validZones.contains(placement.zone) { matches.append(placement) }
                    continue
                }
                guard matchesRecordedPlacement(
                    window.frame,
                    placement.appliedFrame,
                    on: screen
                ) else {
                    invalidLocks.append(identity)
                    continue
                }
                if validZones.contains(placement.zone) { matches.append(placement) }
                continue
            }

            if !windowService.isWindowAlive(element: placement.element, pid: placement.pid) {
                closedWindows.append(identity)
            }
        }

        invalidLocks.forEach {
            lockedPlacements.removeValue(forKey: $0)
            removeConnections(for: $0)
        }
        closedWindows.forEach {
            lockedPlacements.removeValue(forKey: $0)
            removeConnections(for: $0)
            restoreFrames.removeValue(forKey: $0)
            constraintHints.removeValue(forKey: $0)
        }
        return matches
    }

    private func matchesRecordedPlacement(
        _ current: CGRect,
        _ recorded: CGRect,
        on screen: NSScreen
    ) -> Bool {
        let tolerance = max(8, min(screen.visibleFrame.width, screen.visibleFrame.height) * 0.008)
        return abs(current.minX - recorded.minX) <= tolerance
            && abs(current.minY - recorded.minY) <= tolerance
            && abs(current.width - recorded.width) <= tolerance
            && abs(current.height - recorded.height) <= tolerance
    }

    private func registerLock(for window: ManagedWindow, zone: SnapZone, on screen: NSScreen) {
        guard let currentDisplayID = displayID(for: screen) else { return }
        removeConnections(for: window.stableIdentity)
        let visibleIDs = windowService.visibleStableIdentities()
        let conflictingIDs = lockedPlacements.compactMap { identity, placement -> String? in
            guard identity != window.stableIdentity,
                  visibleIDs.contains(identity),
                  zonesOverlap(placement.zone, zone),
                  placement.displayID == currentDisplayID else { return nil }
            return identity
        }
        conflictingIDs.forEach {
            lockedPlacements.removeValue(forKey: $0)
            removeConnections(for: $0)
        }

        lockedPlacements[window.stableIdentity] = LockedPlacement(
            element: window.element,
            pid: window.pid,
            stableIdentity: window.stableIdentity,
            zone: zone,
            displayID: currentDisplayID,
            appliedFrame: window.frame
        )
    }

    private func removeConnections(for stableIdentity: String) {
        detachedConnections = Set(
            detachedConnections.filter { !$0.contains(stableIdentity) }
        )
    }

    private func zonesOverlap(_ lhs: SnapZone, _ rhs: SnapZone) -> Bool {
        !logicalCells(for: lhs).isDisjoint(with: logicalCells(for: rhs))
    }

    private func logicalCells(for zone: SnapZone) -> Set<SnapZone> {
        switch zone {
        case .leftHalf:
            return [.topLeft, .bottomLeft]
        case .rightHalf:
            return [.topRight, .bottomRight]
        case .topHalf:
            return [.topLeft, .topRight]
        case .bottomHalf:
            return [.bottomLeft, .bottomRight]
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return [zone]
        case .maximize:
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
    }

    private func handleActiveSpaceChange() {
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
        }
        resizeHandleOverlay.hideAll()
        invalidatePendingOperations()
        resetSideDwellState()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        activeSession = nil
        activeTarget = nil
        dragDisplayID = nil
        dragScreenFrame = nil
        suppressedEntryEdge = nil
        suppressedDisplayID = nil

        guard CGEventSource.buttonState(.combinedSessionState, button: .left),
              pendingDragWindow != nil || dragWindow != nil else {
            resetDragState()
            return
        }
    }

    private func invalidatePendingOperations(rollbackPendingPlacements: Bool = true) {
        interactionGeneration &+= 1
        invalidatePendingGroupRaise()
        isAssistPlacementPending = false
        windowService.cancelAllFrameOperations()
        let invalidatedHandleSession = handleResizeSession
            ?? finalizingHandleResizeSession
        handleResizeSession = nil
        finalizingHandleResizeSession = nil
        if let invalidatedHandleSession {
            updateHandleSettlementOverlay(
                invalidatedHandleSession,
                restoreOriginalFrames: true
            )
            isHandleResizeFinalizing = true
            stopEscapeMonitoring()
            let identities = Set(invalidatedHandleSession.participants.keys)
            liveResizeScheduler.stop(
                generation: invalidatedHandleSession.schedulerGeneration
            ) { [weak self] in
                guard let self else { return }
                for snapshot in invalidatedHandleSession.snapshots {
                    if snapshot.wasFullscreen {
                        _ = self.windowService.setFullscreen(
                            true,
                            for: snapshot.element
                        )
                    } else {
                        _ = self.windowService.setFrame(
                            snapshot.frame,
                            for: snapshot.element
                        )
                    }
                }
                self.isHandleResizeFinalizing = false
                self.inFlightPlacementIDs.subtract(identities)
                self.virtualResizeOverlay.hideAll()
                self.resizeHandleOverlay.endInteraction()
                self.refreshResizeHandles()
            }
        } else {
            liveResizeScheduler.cancelAll()
        }
        inFlightPlacementIDs.removeAll()
        guard rollbackPendingPlacements else { return }

        let pending = Array(pendingPlacementSnapshots.values)
        pendingPlacementSnapshots.removeAll()
        for snapshot in pending {
            if snapshot.wasFullscreen {
                _ = windowService.setFullscreen(true, for: snapshot.element)
            } else {
                _ = windowService.setFrame(snapshot.frame, for: snapshot.element)
            }
        }
    }

    private func cancelAssist() {
        if handleResizeSession != nil {
            cancelHandleResize(restoreOriginalFrames: true)
            return
        }
        invalidatePendingOperations()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        virtualResizeOverlay.hideAll()
        resetDragState()
        activeSession = nil

        // A normal click is also routed through this cancellation path before
        // drag detection begins. Rebuilding in place avoids destroying and
        // recreating the handle panels on every tab/title-bar click.
        refreshResizeHandles()
    }

    private func resetDragState() {
        cancelSmoothDragRestore()
        resetSideDwellState()
        activeTarget = nil
        pendingDragWindow = nil
        pendingDragWindowFrame = nil
        pendingDragMousePoint = nil
        pendingDragStartedInLikelyDragRegion = false
        pendingDragStartedNearResizeEdge = false
        isWindowMoveConfirmed = false
        sourceDragWindow = nil
        windowIDsAtDragStart.removeAll()
        pendingRestoreFrame = nil
        dragRestoreFrameCandidate = nil
        pendingGrabRatio = nil
        hasWindowActuallyMoved = false
        didStartDragRestore = false
        detachedCandidateID = nil
        detachedCandidateHitCount = 0
        manualResizeWindow = nil
        manualResizeSession = nil
        manualResizeWindowServerCalibration = nil
        dragWindow = nil
        dragDisplayID = nil
        dragScreenFrame = nil
        suppressedEntryEdge = nil
        suppressedDisplayID = nil
    }


    private func isLikelyWindowDragRegion(_ point: CGPoint, window: ManagedWindow) -> Bool {
        guard window.frame.contains(point) else { return false }

        let bandHeight = min(88, max(36, window.frame.height * 0.14))
        return point.y >= window.frame.maxY - bandHeight
    }

    private func isNearWindowResizeEdge(_ point: CGPoint, frame: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else {
            return false
        }
        return abs(point.x - frame.minX) <= tolerance
            || abs(point.x - frame.maxX) <= tolerance
            || abs(point.y - frame.minY) <= tolerance
            || abs(point.y - frame.maxY) <= tolerance
    }

    private var currentEdgeThreshold: CGFloat {
        CGFloat(settings.edgeThreshold)
    }

    private var currentCornerBand: CGFloat {
        CGFloat(settings.cornerBand)
    }

    private func updateSideDwell(for target: SnapTarget, at point: CGPoint, on screen: NSScreen) {
        if let expandedSideContext {
            if expandedSideContext.displayID == target.displayID,
               isAtSideEdge(point, edge: expandedSideContext.edge, on: screen) {
                return
            }
            resetSideDwellState()
        }

        guard settings.sideDwellExpansionEnabled,
              let edge = sideEdge(for: target.zone),
              isAtSideEdge(point, edge: edge, on: screen) else {
            resetSideDwellState()
            return
        }

        let context = SideDwellContext(displayID: target.displayID, edge: edge)
        guard sideDwellContext != context else { return }
        resetSideDwellState()
        sideDwellContext = context

        let totalDuration = settings.sideDwellDuration
        let pulseDuration = min(OverlayPanel.sideExpansionPulseDuration, totalDuration)
        let pulseDelay = max(totalDuration - pulseDuration, 0)

        let pulseTimer = Timer(timeInterval: pulseDelay, repeats: false) { [weak self] _ in
            self?.beginSideDwellPulse(context, duration: pulseDuration)
        }
        sideDwellPulseTimer = pulseTimer
        RunLoop.main.add(pulseTimer, forMode: .common)
    }

    private func beginSideDwellPulse(_ context: SideDwellContext, duration: TimeInterval) {
        sideDwellPulseTimer = nil
        guard settings.sideDwellExpansionEnabled,
              sideDwellContext == context,
              CGEventSource.buttonState(.combinedSessionState, button: .left),
              let screen = screen(withDisplayID: context.displayID) else {
            resetSideDwellState()
            return
        }

        let point = NSEvent.mouseLocation
        guard let currentScreen = screenOwning(point),
              displayID(for: currentScreen) == context.displayID,
              isAtSideEdge(point, edge: context.edge, on: screen) else {
            resetSideDwellState()
            return
        }

        overlay.pulse(times: 3, duration: duration)
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.activateExpandedSideSelection(context)
        }
        sideDwellTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func activateExpandedSideSelection(_ context: SideDwellContext) {
        guard settings.sideDwellExpansionEnabled,
              sideDwellContext == context,
              CGEventSource.buttonState(.combinedSessionState, button: .left),
              let screen = screen(withDisplayID: context.displayID) else {
            resetSideDwellState()
            return
        }

        let point = NSEvent.mouseLocation
        guard let currentScreen = screenOwning(point),
              displayID(for: currentScreen) == context.displayID,
              isAtSideEdge(point, edge: context.edge, on: screen) else {
            resetSideDwellState()
            return
        }

        sideDwellTimer = nil
        sideDwellPulseTimer = nil
        overlay.finishPulse()
        expandedSideContext = context
        activeTarget = nil
        handleDrag(at: point)
    }

    private func expandedSideZone(at point: CGPoint, edge: SideSnapEdge, on screen: NSScreen) -> SnapZone {
        let frame = screen.frame
        let relativeY = min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1)
        if relativeY >= 0.6 {
            return edge == .left ? .topLeft : .topRight
        }
        if relativeY <= 0.4 {
            return edge == .left ? .bottomLeft : .bottomRight
        }
        return edge == .left ? .leftHalf : .rightHalf
    }

    private func sideEdge(for zone: SnapZone) -> SideSnapEdge? {
        switch zone {
        case .leftHalf, .topLeft, .bottomLeft:
            return .left
        case .rightHalf, .topRight, .bottomRight:
            return .right
        default:
            return nil
        }
    }

    private func isAtSideEdge(_ point: CGPoint, edge: SideSnapEdge, on screen: NSScreen) -> Bool {
        let threshold = max(currentEdgeThreshold + 8, currentEdgeThreshold * 1.25)
        switch edge {
        case .left:
            return point.x <= screen.frame.minX + threshold
        case .right:
            return point.x >= screen.frame.maxX - threshold
        }
    }

    private func resetSideDwellState() {
        sideDwellTimer?.invalidate()
        sideDwellTimer = nil
        sideDwellPulseTimer?.invalidate()
        sideDwellPulseTimer = nil
        overlay.finishPulse()
        sideDwellContext = nil
        expandedSideContext = nil
    }

    private func detectSnapZone(at point: CGPoint, on screen: NSScreen) -> SnapZone? {
        SnapZone.detect(
            at: point,
            on: screen,
            edgeThreshold: currentEdgeThreshold,
            cornerBand: currentCornerBand
        )
    }

    private func isNearSnapEdge(_ point: CGPoint) -> Bool {
        guard let screen = screenOwning(point) else { return false }
        return detectSnapZone(at: point, on: screen) != nil
    }

    private func ensurePermission() -> Bool {
        if windowService.isTrusted { return true }
        return windowService.requestPermissionIfNeeded()
    }

    private func snapTarget(at point: CGPoint, shouldUpdateDisplayTransition: Bool) -> SnapTarget? {
        guard let screen = screenOwning(point),
              let displayID = displayID(for: screen) else { return nil }

        if shouldUpdateDisplayTransition {
            updateDisplayTransition(to: screen, displayID: displayID, point: point)
        }

        if suppressedDisplayID == displayID,
           let edge = suppressedEntryEdge {
            if isInsideEntryBand(point, edge: edge, screen: screen) {
                return nil
            }
            suppressedEntryEdge = nil
            suppressedDisplayID = nil
        }

        if let context = expandedSideContext {
            if context.displayID == displayID,
               isAtSideEdge(point, edge: context.edge, on: screen) {
                return SnapTarget(
                    displayID: displayID,
                    zone: expandedSideZone(at: point, edge: context.edge, on: screen)
                )
            }
            resetSideDwellState()
        }

        let detectedZone = detectSnapZone(at: point, on: screen)

        if let activeTarget,
           activeTarget.displayID == displayID,
           let detectedZone,
           shouldPreferDetectedCorner(
               detectedZone,
               over: activeTarget.zone
           ) {
            return SnapTarget(displayID: displayID, zone: detectedZone)
        }

        if let activeTarget,
           activeTarget.displayID == displayID,
           shouldKeepActiveTarget(activeTarget, at: point, on: screen) {
            return activeTarget
        }

        guard let detectedZone else { return nil }
        return SnapTarget(displayID: displayID, zone: detectedZone)
    }

    private func shouldPreferDetectedCorner(
        _ detectedZone: SnapZone,
        over activeZone: SnapZone
    ) -> Bool {
        switch (activeZone, detectedZone) {
        case (.leftHalf, .topLeft),
             (.leftHalf, .bottomLeft),
             (.rightHalf, .topRight),
             (.rightHalf, .bottomRight),
             (.maximize, .topLeft),
             (.maximize, .topRight):
            return true
        default:
            return false
        }
    }

    private func shouldKeepActiveTarget(_ target: SnapTarget, at point: CGPoint, on screen: NSScreen) -> Bool {
        let frame = screen.frame
        let exitThreshold = max(currentEdgeThreshold + 8, currentEdgeThreshold * 1.25)
        let cornerBand = currentCornerBand + 20

        switch target.zone {
        case .leftHalf:
            return point.x <= frame.minX + exitThreshold
        case .rightHalf:
            return point.x >= frame.maxX - exitThreshold
        case .topHalf, .bottomHalf:
            return false
        case .maximize:
            return point.y >= frame.maxY - exitThreshold
        case .topLeft:
            return point.x <= frame.minX + exitThreshold && point.y >= frame.maxY - cornerBand
        case .topRight:
            return point.x >= frame.maxX - exitThreshold && point.y >= frame.maxY - cornerBand
        case .bottomLeft:
            return point.x <= frame.minX + exitThreshold && point.y <= frame.minY + cornerBand
        case .bottomRight:
            return point.x >= frame.maxX - exitThreshold && point.y <= frame.minY + cornerBand
        }
    }

    private func updateDisplayTransition(to screen: NSScreen, displayID: CGDirectDisplayID, point: CGPoint) {
        guard dragDisplayID != displayID else { return }

        if let previousFrame = dragScreenFrame,
           let entryEdge = sharedEntryEdge(from: previousFrame, to: screen.frame, at: point) {
            suppressedEntryEdge = entryEdge
            suppressedDisplayID = displayID
        } else {
            suppressedEntryEdge = nil
            suppressedDisplayID = nil
        }

        dragDisplayID = displayID
        dragScreenFrame = screen.frame
        resetSideDwellState()
        activeTarget = nil
        overlay.hide()
    }

    private func sharedEntryEdge(from oldFrame: CGRect, to newFrame: CGRect, at point: CGPoint) -> SnapEntryEdge? {
        let tolerance: CGFloat = 2
        let verticalOverlap = min(oldFrame.maxY, newFrame.maxY) - max(oldFrame.minY, newFrame.minY)
        let horizontalOverlap = min(oldFrame.maxX, newFrame.maxX) - max(oldFrame.minX, newFrame.minX)

        if verticalOverlap > 0 {
            if abs(oldFrame.maxX - newFrame.minX) <= tolerance { return .left }
            if abs(oldFrame.minX - newFrame.maxX) <= tolerance { return .right }
        }
        if horizontalOverlap > 0 {
            if abs(oldFrame.maxY - newFrame.minY) <= tolerance { return .bottom }
            if abs(oldFrame.minY - newFrame.maxY) <= tolerance { return .top }
        }
        return nil
    }

    private func isInsideEntryBand(_ point: CGPoint, edge: SnapEntryEdge, screen: NSScreen) -> Bool {
        let threshold: CGFloat = 18
        let frame = screen.frame
        switch edge {
        case .left:
            return point.x < frame.minX + threshold
        case .right:
            return point.x >= frame.maxX - threshold
        case .top:
            return point.y >= frame.maxY - threshold
        case .bottom:
            return point.y < frame.minY + threshold
        }
    }

    private func screenOwning(_ point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x < frame.maxX
                && point.y >= frame.minY && point.y < frame.maxY
        }) {
            return exact
        }

        return NSScreen.screens.min { distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame) }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func screen(withDisplayID targetDisplayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == targetDisplayID }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        screenOwning(point)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
