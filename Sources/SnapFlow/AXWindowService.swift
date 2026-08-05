import AppKit
import ApplicationServices
import CoreGraphics

struct ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let appIcon: NSImage?
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let cgWindowID: CGWindowID?

    var stableIdentity: String {
        return "ax:\(pid):\(CFHash(element))"
    }

    func replacingFrame(_ newFrame: CGRect) -> ManagedWindow {
        ManagedWindow(
            element: element,
            pid: pid,
            title: title,
            appIcon: appIcon,
            frame: newFrame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            cgWindowID: cgWindowID
        )
    }

    func replacingCGWindowID(_ newWindowID: CGWindowID?) -> ManagedWindow {
        ManagedWindow(
            element: element,
            pid: pid,
            title: title,
            appIcon: appIcon,
            frame: frame,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            cgWindowID: newWindowID
        )
    }
}

struct WindowSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let stableIdentity: String
    let frame: CGRect
    let wasFullscreen: Bool
}

final class AXWindowService {
    private struct CGWindowRecord {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
        let zIndex: Int
    }

    private var hasPromptedForPermission = false
    private var frameOperationGenerations: [String: Int] = [:]
    private var frameAnimationTimers: [String: Timer] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if isTrusted { return true }
        guard !hasPromptedForPermission else { return false }
        hasPromptedForPermission = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func focusedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = copyAttribute(appElement, kAXFocusedWindowAttribute as CFString) else { return nil }
        return makeManagedWindow(window, pid: app.processIdentifier, app: app, cgWindowID: nil)
    }

    func refreshed(_ window: ManagedWindow) -> ManagedWindow? {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return nil }
        return makeManagedWindow(
            window.element,
            pid: window.pid,
            app: app,
            cgWindowID: window.cgWindowID
        )
    }

    func refreshedFrame(_ window: ManagedWindow) -> CGRect? {
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else { return nil }
        return frame(of: window.element)
    }

    func resolvingWindowServerIdentity(_ window: ManagedWindow) -> ManagedWindow {
        guard window.cgWindowID == nil else { return window }
        let candidates = onscreenWindowRecords().filter {
            $0.pid == window.pid && visibleGeometryMatches(axWindow: window, cgWindow: $0)
        }
        guard let match = candidates.min(by: { lhs, rhs in
            let lhsScore = matchScore(axWindow: window, cgWindow: lhs)
            let rhsScore = matchScore(axWindow: window, cgWindow: rhs)
            if lhsScore == rhsScore {
                return lhs.zIndex < rhs.zIndex
            }
            return lhsScore > rhsScore
        }) else { return window }
        return window.replacingCGWindowID(match.id)
    }

    func windowServerFrame(_ window: ManagedWindow) -> CGRect? {
        guard let windowID = window.cgWindowID else { return nil }
        let requestedIDs = [NSNumber(value: windowID)] as CFArray
        let descriptions = CGWindowListCreateDescriptionFromArray(requestedIDs)
            as? [[String: Any]] ?? []
        guard let item = descriptions.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }),
              (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.pid,
              ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0 else {
            return nil
        }
        let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard let bounds = CGRect(
            dictionaryRepresentation: boundsDictionary as CFDictionary
        ), bounds.width > 0, bounds.height > 0 else { return nil }
        return cgBoundsToCocoa(bounds)
    }

    func visibleWindows(excludingStableIDs excludedStableIDs: Set<String> = []) -> [ManagedWindow] {
        let cgWindows = onscreenWindowRecords()
        let visiblePIDs = Set(cgWindows.map(\.pid))
        var orderedResult: [(window: ManagedWindow, zIndex: Int)] = []
        var seen = Set<String>()

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard visiblePIDs.contains(pid), pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let matches = matchedWindows(for: app, cgWindows: cgWindows)
            for match in matches {
                let managed = match.window
                guard
                      managed.cgWindowID != nil,
                      !managed.isMinimized,
                      managed.frame.width > 180,
                      managed.frame.height > 100,
                      !excludedStableIDs.contains(managed.stableIdentity),
                      seen.insert(managed.stableIdentity).inserted else { continue }
                orderedResult.append(match)
            }
        }

        return orderedResult
            .sorted { lhs, rhs in
                if lhs.zIndex == rhs.zIndex {
                    return lhs.window.stableIdentity < rhs.window.stableIdentity
                }
                return lhs.zIndex < rhs.zIndex
            }
            .map(\.window)
    }

    func windowIdentities(forPID pid: pid_t) -> Set<String> {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = copyAttribute(appElement, kAXWindowsAttribute as CFString) ?? []
        return Set(windows.compactMap {
            makeManagedWindow($0, pid: pid, app: app, cgWindowID: nil)?.stableIdentity
        })
    }

    func visibleStableIdentities() -> Set<String> {
        Set(visibleWindows().map(\.stableIdentity))
    }

    func isWindowAlive(element: AXUIElement, pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
        return role == kAXWindowRole && frame(of: element) != nil
    }


    func canMoveAndResize(_ window: ManagedWindow) -> Bool {
        isAttributeSettable(kAXPositionAttribute as CFString, on: window.element)
            && isAttributeSettable(kAXSizeAttribute as CFString, on: window.element)
    }

    func snapshot(_ window: ManagedWindow) -> WindowSnapshot {
        WindowSnapshot(
            element: window.element,
            pid: window.pid,
            stableIdentity: window.stableIdentity,
            frame: window.frame,
            wasFullscreen: window.isFullscreen
        )
    }

    @discardableResult
    func setFrame(_ frame: CGRect, for window: AXUIElement) -> Bool {
        let firstPositionResult = setPosition(frame.origin, targetHeight: frame.height, for: window)
        let sizeResult = setSize(frame.size, for: window)
        let finalPositionResult = setPosition(frame.origin, targetHeight: frame.height, for: window)
        return firstPositionResult && sizeResult && finalPositionResult
    }

    func setFrameReliably(
        _ targetFrame: CGRect,
        for window: AXUIElement,
        completion: @escaping (Bool) -> Void
    ) {
        let operation = beginFrameOperation(for: window)
        setFrameReliably(
            targetFrame,
            for: window,
            operationKey: operation.key,
            generation: operation.generation,
            completion: completion
        )
    }

    private func setFrameReliably(
        _ targetFrame: CGRect,
        for window: AXUIElement,
        operationKey: String,
        generation: Int,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        guard isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

        if let actualFrame = frame(of: window),
           framesMatch(actualFrame, targetFrame) {
            completion(true)
            return
        }

        _ = setPosition(targetFrame.origin, targetHeight: targetFrame.height, for: window)
        let preparationDelays: [TimeInterval] = [0.05, 0.06, 0.08, 0.10]
        let settleDelays: [TimeInterval] = [0.08, 0.11, 0.16, 0.20]
        let delayIndex = Swift.min(attempt, preparationDelays.count - 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + preparationDelays[delayIndex]) { [weak self] in
            guard let self,
                  self.isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

            _ = self.setSize(targetFrame.size, for: window)
            _ = self.setPosition(
                targetFrame.origin,
                targetHeight: targetFrame.height,
                for: window
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelays[delayIndex]) { [weak self] in
                guard let self,
                      self.isCurrentFrameOperation(key: operationKey, generation: generation) else { return }

                if let actualFrame = self.frame(of: window),
                   self.framesMatch(actualFrame, targetFrame) {
                    completion(true)
                    return
                }

                let nextAttempt = attempt + 1
                guard nextAttempt < preparationDelays.count else {
                    completion(false)
                    return
                }
                self.setFrameReliably(
                    targetFrame,
                    for: window,
                    operationKey: operationKey,
                    generation: generation,
                    attempt: nextAttempt,
                    completion: completion
                )
            }
        }
    }

    func setFrameAnchoredReliably(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        requiredOuterEdges: SnapOuterEdges = [],
        for window: AXUIElement,
        afterInitialFrameAttempt: (() -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let operation = beginFrameOperation(for: window)
        setFrameAnchoredAndObserved(
            targetFrame,
            sizeConstraintAnchor: sizeConstraintAnchor,
            requiredOuterEdges: requiredOuterEdges,
            for: window,
            operationKey: operation.key,
            generation: operation.generation,
            afterInitialFrameAttempt: afterInitialFrameAttempt,
            completion: completion
        )
    }

    private func setFrameAnchoredAndObserved(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        requiredOuterEdges: SnapOuterEdges,
        for window: AXUIElement,
        operationKey: String,
        generation: Int,
        afterInitialFrameAttempt: (() -> Void)?,
        completion: @escaping (Bool) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let requiresExactWidth = requiredOuterEdges.contains(.horizontal)
        let requiresExactHeight = requiredOuterEdges.contains(.vertical)
        let hasRequiredExactDimension = requiresExactWidth || requiresExactHeight
        let settlingTimeout: TimeInterval = hasRequiredExactDimension ? 1.8 : 0.9
        let timeoutAt = startedAt + settlingTimeout
        var previousObservedSize: CGSize?
        var stableSizeTransitions = 0
        var acceptedPlacementSamples = 0
        var lastCorrectionAt = startedAt
        var finalSizeRequestAt = startedAt
        var finalSizeRequestCount = 0
        var exactCorrectionCount = 0
        var previousTargetDistance: CGFloat?
        var lastTargetProgressAt = startedAt
        var placementAcceptedAt: TimeInterval?
        var completionDelivered = false

        _ = setFinalFrameCorrection(
            targetFrame,
            sizeConstraintAnchor: sizeConstraintAnchor,
            for: window
        )
        finalSizeRequestCount = 1

        if let afterInitialFrameAttempt,
           isCurrentFrameOperation(key: operationKey, generation: generation) {
            afterInitialFrameAttempt()
            if isCurrentFrameOperation(key: operationKey, generation: generation) {
                _ = setFinalFrameCorrection(
                    targetFrame,
                    sizeConstraintAnchor: sizeConstraintAnchor,
                    for: window
                )
                finalSizeRequestAt = ProcessInfo.processInfo.systemUptime
                finalSizeRequestCount += 1
            }
        }

        guard isCurrentFrameOperation(
            key: operationKey,
            generation: generation
        ) else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self,
                  self.isCurrentFrameOperation(key: operationKey, generation: generation) else {
                timer.invalidate()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard let actualFrame = self.frame(of: window) else {
                guard now >= timeoutAt else { return }
                completionDelivered = true
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                completion(false)
                return
            }

            if let previousObservedSize,
               self.sizesMatch(actualFrame.size, previousObservedSize, tolerance: 2) {
                stableSizeTransitions += 1
            } else {
                stableSizeTransitions = 0
            }
            previousObservedSize = actualFrame.size

            let effectiveFrame = self.anchoredFrame(
                targetFrame,
                actualSize: actualFrame.size,
                anchor: sizeConstraintAnchor
            )
            let anchorIsCorrect = self.originsMatch(
                actualFrame.origin,
                effectiveFrame.origin,
                tolerance: 1
            )
            let exactSizeIsCorrect = self.sizesMatch(
                actualFrame.size,
                targetFrame.size,
                tolerance: 1
            )
            let requiredSizeIsCorrect =
                (!requiresExactWidth
                    || abs(actualFrame.width - targetFrame.width) <= 1)
                && (!requiresExactHeight
                    || abs(actualFrame.height - targetFrame.height) <= 1)
            let requiredEdgesAreCorrect = self.requiredOuterEdgesMatch(
                actualFrame,
                targetFrame,
                requiredEdges: requiredOuterEdges
            )

            if hasRequiredExactDimension {
                let targetDistance = abs(actualFrame.minX - targetFrame.minX)
                    + abs(actualFrame.minY - targetFrame.minY)
                    + abs(actualFrame.width - targetFrame.width)
                    + abs(actualFrame.height - targetFrame.height)
                if let previousTargetDistance,
                   previousTargetDistance - targetDistance >= 1 {
                    lastTargetProgressAt = now
                }
                previousTargetDistance = targetDistance
            }

            let acceptedSizeIsStable = stableSizeTransitions >= 1
            let settledAfterFinalSizeRequest = now - finalSizeRequestAt >= 0.08
            let finalTargetWasObserved = exactSizeIsCorrect
                || (finalSizeRequestCount >= 2 && settledAfterFinalSizeRequest)
            let placementIsAcceptable = requiredSizeIsCorrect
                && requiredEdgesAreCorrect
                && finalTargetWasObserved

            if placementIsAcceptable && acceptedSizeIsStable {
                acceptedPlacementSamples += 1
                if placementAcceptedAt == nil {
                    placementAcceptedAt = now
                }
            } else {
                acceptedPlacementSamples = 0
                placementAcceptedAt = nil
            }

            let verificationDuration: TimeInterval = hasRequiredExactDimension ? 0.08 : 0.04
            if acceptedPlacementSamples >= 2,
               let placementAcceptedAt,
               now - placementAcceptedAt >= verificationDuration {
                guard !completionDelivered else { return }
                completionDelivered = true
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                completion(true)
                return
            }

            guard now < timeoutAt else {
                guard !completionDelivered else { return }
                completionDelivered = true
                timer.invalidate()
                self.frameAnimationTimers.removeValue(forKey: operationKey)
                completion(false)
                return
            }

            if hasRequiredExactDimension, !placementIsAcceptable {
                let correctionIntervals: [TimeInterval] = [0.10, 0.16, 0.24, 0.32]
                let correctionInterval = correctionIntervals[
                    Swift.min(exactCorrectionCount, correctionIntervals.count - 1)
                ]
                let applicationIsStillResponding = now - lastTargetProgressAt < 0.10
                if now - lastCorrectionAt >= correctionInterval,
                   !applicationIsStillResponding {
                    var issuedCorrection = false

                    if !requiredSizeIsCorrect
                        || (!exactSizeIsCorrect && finalSizeRequestCount < 2) {
                        _ = self.setFinalFrameCorrection(
                            targetFrame,
                            sizeConstraintAnchor: sizeConstraintAnchor,
                            for: window
                        )
                        finalSizeRequestAt = now
                        finalSizeRequestCount += 1
                        issuedCorrection = true
                    } else if !requiredEdgesAreCorrect {
                        _ = self.setPosition(
                            effectiveFrame.origin,
                            targetHeight: effectiveFrame.height,
                            for: window
                        )
                        issuedCorrection = true
                    }

                    if issuedCorrection {
                        exactCorrectionCount += 1
                        lastCorrectionAt = now
                        lastTargetProgressAt = now
                        previousTargetDistance = nil
                        previousObservedSize = nil
                        stableSizeTransitions = 0
                        acceptedPlacementSamples = 0
                        placementAcceptedAt = nil
                    }
                }
            } else if !hasRequiredExactDimension,
                      now - lastCorrectionAt >= 0.10 {
                if !exactSizeIsCorrect,
                   finalSizeRequestCount < 2 {
                    _ = self.setFinalFrameCorrection(
                        targetFrame,
                        sizeConstraintAnchor: sizeConstraintAnchor,
                        for: window
                    )
                    finalSizeRequestAt = now
                    finalSizeRequestCount += 1
                    previousObservedSize = nil
                    stableSizeTransitions = 0
                    acceptedPlacementSamples = 0
                    placementAcceptedAt = nil
                } else if !anchorIsCorrect {
                    _ = self.setPosition(
                        effectiveFrame.origin,
                        targetHeight: effectiveFrame.height,
                        for: window
                    )
                }
                lastCorrectionAt = now
            }
        }
        frameAnimationTimers[operationKey] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func setFinalFrameCorrection(
        _ targetFrame: CGRect,
        sizeConstraintAnchor: CGPoint,
        for window: AXUIElement
    ) -> Bool {
        let preparationPositionResult = setPosition(
            targetFrame.origin,
            targetHeight: targetFrame.height,
            for: window
        )
        let sizeResult = setSize(targetFrame.size, for: window)
        guard let acceptedSize = frame(of: window)?.size else { return false }
        let acceptedFrame = anchoredFrame(
            targetFrame,
            actualSize: acceptedSize,
            anchor: sizeConstraintAnchor
        )
        let finalPositionResult = setPosition(
            acceptedFrame.origin,
            targetHeight: acceptedFrame.height,
            for: window
        )
        return preparationPositionResult && sizeResult && finalPositionResult
    }

    func cancelFrameOperation(for window: AXUIElement) {
        let key = frameOperationKey(for: window)
        frameAnimationTimers.removeValue(forKey: key)?.invalidate()
        frameOperationGenerations[key, default: 0] += 1
    }

    func cancelAllFrameOperations() {
        let keys = Set(frameOperationGenerations.keys).union(frameAnimationTimers.keys)
        frameAnimationTimers.values.forEach { $0.invalidate() }
        frameAnimationTimers.removeAll()
        keys.forEach { frameOperationGenerations[$0, default: 0] += 1 }
    }

    private func beginFrameOperation(for window: AXUIElement) -> (key: String, generation: Int) {
        let key = frameOperationKey(for: window)
        frameAnimationTimers.removeValue(forKey: key)?.invalidate()
        let generation = frameOperationGenerations[key, default: 0] + 1
        frameOperationGenerations[key] = generation
        return (key, generation)
    }

    private func frameOperationKey(for window: AXUIElement) -> String {
        "ax:\(CFHash(window))"
    }

    private func isCurrentFrameOperation(key: String, generation: Int) -> Bool {
        frameOperationGenerations[key] == generation
    }

    @discardableResult
    private func setPosition(_ origin: CGPoint, targetHeight: CGFloat, for window: AXUIElement) -> Bool {
        var position = cocoaPointToAX(origin, height: targetHeight)
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    @discardableResult
    private func setSize(_ targetSize: CGSize, for window: AXUIElement) -> Bool {
        var size = targetSize
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            value
        ) == .success
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func requiredOuterEdgesMatch(
        _ frame: CGRect,
        _ targetFrame: CGRect,
        requiredEdges: SnapOuterEdges,
        tolerance: CGFloat = 1
    ) -> Bool {
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

    private func originsMatch(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        tolerance: CGFloat = 5
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
    }

    private func sizesMatch(
        _ lhs: CGSize,
        _ rhs: CGSize,
        tolerance: CGFloat = 5
    ) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    @discardableResult
    func setFullscreen(_ fullscreen: Bool, for window: AXUIElement) -> Bool {
        let value: CFBoolean = fullscreen ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value) == .success
    }

    func isFullscreen(_ window: AXUIElement) -> Bool {
        copyAttribute(window, "AXFullScreen" as CFString) ?? false
    }

    func focus(_ window: ManagedWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    func waitForPlacementReadiness(
        _ window: ManagedWindow,
        minimumDelay: TimeInterval = 0.06,
        timeout: TimeInterval = 0.45,
        shouldContinue: @escaping () -> Bool = { true },
        completion: @escaping (ManagedWindow?) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime

        func checkReadiness() {
            guard shouldContinue() else { return }
            guard let app = NSRunningApplication(processIdentifier: window.pid),
                  !app.isTerminated else {
                completion(nil)
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let current = refreshed(window)
            let isReady = current.map(canMoveAndResize) == true

            if elapsed >= minimumDelay, isReady {
                completion(current)
                return
            }

            guard elapsed < timeout else {
                if let current, canMoveAndResize(current) {
                    completion(current)
                } else {
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: checkReadiness)
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + minimumDelay,
            execute: checkReadiness
        )
    }

    func restore(_ snapshot: WindowSnapshot, completion: @escaping (Bool) -> Void) {
        if snapshot.wasFullscreen {
            guard setFullscreen(true, for: snapshot.element) else {
                completion(false)
                return
            }
            waitForFullscreenState(true, for: snapshot.element, completion: completion)
        } else {
            setFrameReliably(snapshot.frame, for: snapshot.element, completion: completion)
        }
    }

    func waitForFullscreenState(
        _ expected: Bool,
        for window: AXUIElement,
        timeout: TimeInterval = 1.2,
        completion: @escaping (Bool) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime

        func check() {
            if isFullscreen(window) == expected {
                completion(true)
                return
            }
            guard ProcessInfo.processInfo.systemUptime - startedAt < timeout else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }

        check()
    }

    private func makeManagedWindow(
        _ element: AXUIElement,
        pid: pid_t,
        app: NSRunningApplication,
        cgWindowID: CGWindowID?
    ) -> ManagedWindow? {
        let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
        guard role == kAXWindowRole else { return nil }
        let subrole: String? = copyAttribute(element, kAXSubroleAttribute as CFString)
        guard subrole != kAXUnknownSubrole else { return nil }
        guard let frame = frame(of: element) else { return nil }
        let title: String = copyAttribute(element, kAXTitleAttribute as CFString) ?? app.localizedName ?? "ウィンドウ"
        let minimized: Bool = copyAttribute(element, kAXMinimizedAttribute as CFString) ?? false
        let fullscreen: Bool = copyAttribute(element, "AXFullScreen" as CFString) ?? false
        return ManagedWindow(
            element: element,
            pid: pid,
            title: title.isEmpty ? (app.localizedName ?? "ウィンドウ") : title,
            appIcon: app.icon,
            frame: frame,
            isMinimized: minimized,
            isFullscreen: fullscreen,
            cgWindowID: cgWindowID
        )
    }

    private func matchedWindows(
        for app: NSRunningApplication,
        cgWindows: [CGWindowRecord]
    ) -> [(window: ManagedWindow, zIndex: Int)] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let elements: [AXUIElement] = copyAttribute(appElement, kAXWindowsAttribute as CFString) ?? []
        let focusedElement: AXUIElement? = copyAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let baseWindows = elements.compactMap {
            makeManagedWindow($0, pid: pid, app: app, cgWindowID: nil)
        }
        let appCGWindows = cgWindows
            .filter { $0.pid == pid }
            .sorted { $0.zIndex < $1.zIndex }
        var unusedAXIndices = Set(baseWindows.indices)
        var result: [(window: ManagedWindow, zIndex: Int)] = []

        for record in appCGWindows {
            let compatibleIndices = unusedAXIndices.filter {
                visibleGeometryMatches(axWindow: baseWindows[$0], cgWindow: record)
            }
            let bestIndex = compatibleIndices.min { lhs, rhs in
                let lhsWindow = baseWindows[lhs]
                let rhsWindow = baseWindows[rhs]
                let lhsScore = matchScore(axWindow: lhsWindow, cgWindow: record)
                    + (focusedElement.map { CFEqual(lhsWindow.element, $0) } == true ? 25 : 0)
                let rhsScore = matchScore(axWindow: rhsWindow, cgWindow: record)
                    + (focusedElement.map { CFEqual(rhsWindow.element, $0) } == true ? 25 : 0)
                if lhsScore == rhsScore {
                    return lhs < rhs
                }
                return lhsScore > rhsScore
            }

            guard let bestIndex else { continue }
            unusedAXIndices.remove(bestIndex)
            let base = baseWindows[bestIndex]
            let matched = makeManagedWindow(
                base.element,
                pid: pid,
                app: app,
                cgWindowID: record.id
            ) ?? base
            result.append((matched, record.zIndex))
        }

        return result
    }

    private func visibleGeometryMatches(
        axWindow: ManagedWindow,
        cgWindow: CGWindowRecord
    ) -> Bool {
        let sizeDelta = abs(cgWindow.frame.width - axWindow.frame.width)
            + abs(cgWindow.frame.height - axWindow.frame.height)
        let originDelta = abs(cgWindow.frame.minX - axWindow.frame.minX)
            + abs(cgWindow.frame.minY - axWindow.frame.minY)
        let referenceLength = max(
            min(cgWindow.frame.width, cgWindow.frame.height),
            1
        )
        let allowedSizeDelta = max(24, referenceLength * 0.08)
        let allowedOriginDelta = max(48, referenceLength * 0.12)
        return sizeDelta <= allowedSizeDelta
            && originDelta <= allowedOriginDelta
    }

    private func matchScore(axWindow: ManagedWindow, cgWindow: CGWindowRecord) -> CGFloat {
        let sizeDelta = abs(cgWindow.frame.width - axWindow.frame.width)
            + abs(cgWindow.frame.height - axWindow.frame.height)
        let originDelta = abs(cgWindow.frame.minX - axWindow.frame.minX)
            + abs(cgWindow.frame.minY - axWindow.frame.minY)
        let exactTitle = !axWindow.title.isEmpty
            && !cgWindow.title.isEmpty
            && axWindow.title == cgWindow.title
        let compatibleTitle = exactTitle || axWindow.title.isEmpty || cgWindow.title.isEmpty
        let titleScore: CGFloat = exactTitle ? 300 : (compatibleTitle ? 30 : 0)
        return titleScore - sizeDelta * 6 - originDelta * 2
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: axPointToCocoa(point, height: size.height), size: size)
    }

    func previewCGImage(for windowID: CGWindowID?) -> CGImage? {
        guard let windowID else { return nil }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    private func onscreenWindowRecords() -> [CGWindowRecord] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return info.enumerated().compactMap { index, item in
            guard ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            return CGWindowRecord(
                id: CGWindowID(idNumber.uint32Value),
                pid: pidNumber.int32Value,
                title: (item[kCGWindowName as String] as? String) ?? "",
                frame: cgBoundsToCocoa(bounds),
                zIndex: index
            )
        }
    }

    private func anchoredFrame(
        _ proposedFrame: CGRect,
        actualSize: CGSize,
        anchor: CGPoint
    ) -> CGRect {
        let safeAnchorX = min(max(anchor.x, 0), 1)
        let safeAnchorY = min(max(anchor.y, 0), 1)
        return CGRect(
            x: proposedFrame.minX + (proposedFrame.width - actualSize.width) * safeAnchorX,
            y: proposedFrame.minY + (proposedFrame.height - actualSize.height) * safeAnchorY,
            width: actualSize.width,
            height: actualSize.height
        )
    }

    private func cocoaPointToAX(_ point: CGPoint, height: CGFloat) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y - height)
    }

    private func axPointToCocoa(_ point: CGPoint, height: CGFloat) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y - height)
    }

    private func cgBoundsToCocoa(_ bounds: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }


    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else { return false }
        return settable.boolValue
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }
}
