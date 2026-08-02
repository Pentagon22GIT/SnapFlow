import AppKit
import ApplicationServices

private struct LockedPlacement {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let zone: SnapZone
    let displayID: CGDirectDisplayID
    let appliedFrame: CGRect
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
                resetDragState()
                activeSession = nil
            }
        }
    }

    private let windowService = AXWindowService()
    private let overlay = OverlayPanel()
    private let picker = WindowPickerPanel()
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
    private var sideDwellTimer: Timer?
    private var sideDwellPulseTimer: Timer?
    private var sideDwellContext: SideDwellContext?
    private var expandedSideContext: SideDwellContext?

    private var dragWindow: ManagedWindow?
    private var dragDisplayID: CGDirectDisplayID?
    private var dragScreenFrame: CGRect?
    private var suppressedEntryEdge: SnapEntryEdge?
    private var suppressedDisplayID: CGDirectDisplayID?
    private var snapshots: [WindowSnapshot] = []
    private var lockedPlacements: [String: LockedPlacement] = [:]
    private var restoreFrames: [String: CGRect] = [:]
    private var activeSession: LayoutSession?
    private var isAssistPlacementPending = false
    private var interactionGeneration = 0
    private var pendingPlacementSnapshots: [String: WindowSnapshot] = [:]

    func start() {
        _ = windowService.requestPermissionIfNeeded()
        installEventMonitors()
        installRecoveryObservers()
        startRecoveryTimer()
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
        resetDragState()
        activeSession = nil
    }

    func reset() {
        isEnabled = true
        snapshots.removeAll()
        lockedPlacements.removeAll()
        restoreFrames.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        resetSideDwellState()
        invalidatePendingOperations()
        settings.resetAll()
        overlay.hide()
        picker.hide()
    }

    func restoreLast() {
        let visibleIDs = windowService.visibleStableIdentities()
        var targetIndex: Int?
        var staleIndices: [Int] = []

        for index in snapshots.indices.reversed() {
            let snapshot = snapshots[index]
            if visibleIDs.contains(snapshot.stableIdentity) {
                targetIndex = index
                break
            }
            if !windowService.isWindowAlive(element: snapshot.element, pid: snapshot.pid) {
                staleIndices.append(index)
                lockedPlacements.removeValue(forKey: snapshot.stableIdentity)
                restoreFrames.removeValue(forKey: snapshot.stableIdentity)
            }
        }

        staleIndices.sorted(by: >).forEach { snapshots.remove(at: $0) }
        guard let targetIndex, snapshots.indices.contains(targetIndex) else { return }
        let snapshot = snapshots[targetIndex]
        invalidatePendingOperations()
        let generation = interactionGeneration

        windowService.restore(snapshot) { [weak self] succeeded in
            guard let self,
                  succeeded,
                  self.interactionGeneration == generation else { return }
            if let currentIndex = self.snapshots.lastIndex(where: {
                $0.stableIdentity == snapshot.stableIdentity
                    && CFEqual($0.element, snapshot.element)
                    && $0.frame == snapshot.frame
            }) {
                self.snapshots.remove(at: currentIndex)
            }
            self.lockedPlacements.removeValue(forKey: snapshot.stableIdentity)
            self.restoreFrames.removeValue(forKey: snapshot.stableIdentity)
        }
    }

    func clearLocks() {
        lockedPlacements.removeAll()
        activeSession = nil
        stopEscapeMonitoring()
        picker.hide()
    }

    func snapFocusedWindow(to zone: SnapZone) {
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
            self?.handle(event)
            return event
        }
    }

    private func startEscapeMonitoring() {
        guard globalEscapeMonitor == nil else { return }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.cancelAssist() }
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

        defaultObservers.append(defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAssist()
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

        if (dragWindow != nil || pendingDragWindow != nil),
           !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            if !finishManualResizeIfNeeded() {
                finishSmoothDragRestore(at: NSEvent.mouseLocation)
            }
            overlay.hide()
            resetDragState()
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

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }
        lastInteractionAt = Date()

        if event.type == .keyDown, event.keyCode == 53 {
            cancelAssist()
            return
        }
        guard ensurePermission() else { return }

        switch event.type {
        case .leftMouseDown:
            let point = NSEvent.mouseLocation

            if picker.isVisible && picker.containsScreenPoint(point) {
                return
            }
            cancelAssist()
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
                if trackManualResizeIfNeeded() {
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
            if finishManualResizeIfNeeded() {
                overlay.hide()
                resetDragState()
                return
            }
            if activeSession == nil {
                handleDrop(at: NSEvent.mouseLocation)
            } else if !picker.isVisible {
                cancelAssist()
            }

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
    }

    private func trackManualResizeIfNeeded() -> Bool {
        guard !isWindowMoveConfirmed,
              !hasWindowActuallyMoved,
              !didStartDragRestore else {
            return false
        }

        if let manualResizeWindow {
            self.manualResizeWindow = windowService.refreshed(manualResizeWindow) ?? manualResizeWindow
            overlay.hide()
            activeTarget = nil
            return true
        }

        guard let originalWindow = pendingDragWindow,
              let originalFrame = pendingDragWindowFrame,
              let currentWindow = windowService.refreshed(originalWindow) else {
            return false
        }

        let sizeTolerance: CGFloat = 1.5
        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width) > sizeTolerance
            || abs(currentWindow.frame.height - originalFrame.height) > sizeTolerance
        guard sizeChanged else { return false }

        manualResizeWindow = currentWindow
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
              let originalFrame = pendingDragWindowFrame,
              let currentWindow = windowService.refreshed(manualResizeWindow ?? originalWindow) else {
            return manualResizeWindow != nil
        }

        let sizeTolerance: CGFloat = 1.5
        let sizeChanged = abs(currentWindow.frame.width - originalFrame.width) > sizeTolerance
            || abs(currentWindow.frame.height - originalFrame.height) > sizeTolerance
        guard manualResizeWindow != nil || sizeChanged else { return false }

        let hasSnapState = restoreFrames[currentWindow.stableIdentity] != nil
            || lockedPlacements[currentWindow.stableIdentity] != nil
        if sizeChanged, hasSnapState {
            restoreFrames[currentWindow.stableIdentity] = currentWindow.frame
        }
        return true
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
        pendingDragWindow = candidate
        pendingDragWindowFrame = candidate.frame
        pendingDragMousePoint = point
        pendingGrabRatio = grabRatio(at: point, in: candidate.frame)
        pendingRestoreFrame = nil
        pendingDragStartedInLikelyDragRegion = true
        dragWindow = candidate
        isWindowMoveConfirmed = true
        hasWindowActuallyMoved = true
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

        if target != activeTarget {
            activeTarget = target
            overlay.show(frame: target.zone.frame(in: screen), from: point)
        }
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

        let applySnap = { [weak self] in
            guard let self,
                  self.interactionGeneration == operationGeneration else { return }
            let targetFrame = zone.frame(in: screen)
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
                        for: zone,
                        on: screen
                    )
                } ?? false
                guard succeeded && requiredEdgesAreCorrect else {
                    self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                    self.rollbackFailedPlacement(pendingSnapshot) {
                        completion?(false)
                    }
                    return
                }
                self.pendingPlacementSnapshots.removeValue(forKey: window.stableIdentity)
                self.commitSnapshot(pendingSnapshot)
                self.restoreFrames[window.stableIdentity] = pendingRestoreCandidate
                let refreshedWindow = appliedWindow ?? window
                self.registerLock(for: refreshedWindow, zone: zone, on: screen)
                self.advanceAssist(
                    with: refreshedWindow,
                    justPlacedZone: zone,
                    on: screen,
                    continueAssist: continueAssist
                )
                completion?(true)
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

    private func matchesRequiredOuterEdges(
        _ frame: CGRect,
        for zone: SnapZone,
        on screen: NSScreen
    ) -> Bool {
        let target = zone.frame(in: screen)
        let requiredEdges = zone.requiredOuterEdges
        let tolerance: CGFloat = 1

        if requiredEdges.contains(.left),
           abs(frame.minX - target.minX) > tolerance {
            return false
        }
        if requiredEdges.contains(.right),
           abs(frame.maxX - target.maxX) > tolerance {
            return false
        }
        if requiredEdges.contains(.top),
           abs(frame.maxY - target.maxY) > tolerance {
            return false
        }
        if requiredEdges.contains(.bottom),
           abs(frame.minY - target.minY) > tolerance {
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

    private func commitSnapshot(_ snapshot: WindowSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > 30 {
            snapshots.removeFirst(snapshots.count - 30)
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
        picker.show(
            windows: candidates,
            zones: remaining,
            screen: screen,
            previewProvider: { [weak self] windowID in
                guard let self, self.settings.windowPreviewsEnabled else { return nil }
                return self.windowService.previewCGImage(for: windowID)
            },
            onCancel: { [weak self] in
                self?.activeSession = nil
                self?.stopEscapeMonitoring()
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
        }
        closedWindows.forEach {
            lockedPlacements.removeValue(forKey: $0)
            restoreFrames.removeValue(forKey: $0)
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
        let visibleIDs = windowService.visibleStableIdentities()
        let conflictingIDs = lockedPlacements.compactMap { identity, placement -> String? in
            guard identity != window.stableIdentity,
                  visibleIDs.contains(identity),
                  zonesOverlap(placement.zone, zone),
                  placement.displayID == currentDisplayID else { return nil }
            return identity
        }
        conflictingIDs.forEach { lockedPlacements.removeValue(forKey: $0) }

        lockedPlacements[window.stableIdentity] = LockedPlacement(
            element: window.element,
            pid: window.pid,
            stableIdentity: window.stableIdentity,
            zone: zone,
            displayID: currentDisplayID,
            appliedFrame: window.frame
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
        invalidatePendingOperations()
        resetSideDwellState()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
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
        isAssistPlacementPending = false
        windowService.cancelAllFrameOperations()
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
        invalidatePendingOperations()
        stopEscapeMonitoring()
        overlay.hide()
        picker.hide()
        resetDragState()
        activeSession = nil
    }

    private func resetDragState() {
        cancelSmoothDragRestore()
        resetSideDwellState()
        activeTarget = nil
        pendingDragWindow = nil
        pendingDragWindowFrame = nil
        pendingDragMousePoint = nil
        pendingDragStartedInLikelyDragRegion = false
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
