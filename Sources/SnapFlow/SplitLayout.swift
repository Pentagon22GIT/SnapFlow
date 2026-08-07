import AppKit

struct SplitPlacementGeometry {
    let stableIdentity: String
    let zone: SnapZone
    let frame: CGRect
}

struct SplitResizeHandleGeometry: Equatable {
    let axis: SplitAxis
    let coordinate: CGFloat
    let span: ClosedRange<CGFloat>
    let participantIDs: Set<String>
}

struct SplitResizeParticipantGeometry {
    let stableIdentity: String
    let frame: CGRect
    let side: SplitBoundarySide
    let minimumLength: CGFloat
}

struct SplitZOrderWindow {
    let stableIdentity: String
    let frame: CGRect
}

enum SplitAxis: CaseIterable, Hashable {
    case horizontal
    case vertical
}

enum SplitBoundarySide: Hashable {
    case nearOrigin
    case farOrigin
}

enum SplitPerpendicularBand: Hashable {
    case first
    case second
}

struct WindowConstraintHint {
    var minimumWidth: CGFloat?
    var minimumHeight: CGFloat?

    mutating func observe(requested: CGSize, accepted: CGSize, tolerance: CGFloat = 2) {
        minimumWidth = Self.updatedHint(
            current: minimumWidth,
            requested: requested.width,
            accepted: accepted.width,
            tolerance: tolerance
        )
        minimumHeight = Self.updatedHint(
            current: minimumHeight,
            requested: requested.height,
            accepted: accepted.height,
            tolerance: tolerance
        )
    }

    func referenceSize(current: CGSize, nominal: CGSize) -> CGSize {
        CGSize(
            width: max(minimumWidth ?? min(current.width, nominal.width), 1),
            height: max(minimumHeight ?? min(current.height, nominal.height), 1)
        )
    }

    private static func updatedHint(
        current: CGFloat?,
        requested: CGFloat,
        accepted: CGFloat,
        tolerance: CGFloat
    ) -> CGFloat? {
        guard requested > 0, accepted > 0 else { return current }
        if accepted > requested + tolerance {
            return accepted
        }
        if let current, requested + tolerance < current {
            return accepted
        }
        return current
    }
}

enum SplitRelationDirection: CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var followerAnchor: CGPoint {
        switch self {
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .top: return CGPoint(x: 0.5, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 0)
        }
    }
}

struct SplitConnectionKey: Hashable {
    let first: String
    let second: String

    init(_ lhs: String, _ rhs: String) {
        if lhs <= rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }

    func contains(_ identity: String) -> Bool {
        first == identity || second == identity
    }
}

enum SplitLayoutGeometry {
    static func connectedGroupIsFrontmost(
        groupIDs: Set<String>,
        orderedWindows: [SplitZOrderWindow]
    ) -> Bool {
        guard groupIDs.count >= 2 else { return true }
        for groupIndex in orderedWindows.indices {
            let groupWindow = orderedWindows[groupIndex]
            guard groupIDs.contains(groupWindow.stableIdentity) else { continue }
            for externalIndex in orderedWindows.indices where externalIndex < groupIndex {
                let externalWindow = orderedWindows[externalIndex]
                if groupIDs.contains(externalWindow.stableIdentity) { continue }
                let intersection = groupWindow.frame.intersection(externalWindow.frame)
                if !intersection.isNull,
                   intersection.width > 1,
                   intersection.height > 1 {
                    return false
                }
            }
        }
        return true
    }

    static let contactTolerance: CGFloat = 8
    static let boundaryMergeTolerance: CGFloat = 1.5
    static let ratioHysteresis: CGFloat = 0.05

    static func resizeAxis(
        forDragDelta delta: CGPoint,
        minimumDistance: CGFloat = 4
    ) -> SplitAxis? {
        guard hypot(delta.x, delta.y) >= minimumDistance else { return nil }
        return abs(delta.x) >= abs(delta.y) ? .horizontal : .vertical
    }

    static func remainsSuspended(
        wasSuspended: Bool,
        compressionRatios: [CGFloat],
        tolerance: CGFloat
    ) -> Bool {
        guard tolerance.isFinite,
              compressionRatios.allSatisfy({ $0.isFinite }) else { return true }
        if wasSuspended {
            let resumeTolerance = max(tolerance - ratioHysteresis, 0)
            return !compressionRatios.allSatisfy { $0 <= resumeTolerance }
        }
        return compressionRatios.contains { $0 > tolerance }
    }

    static func resizeHandleGeometries(
        placements: [SplitPlacementGeometry],
        detachedConnections: Set<SplitConnectionKey> = [],
        tolerance: CGFloat = contactTolerance,
        mergeTolerance: CGFloat = boundaryMergeTolerance
    ) -> [SplitResizeHandleGeometry] {
        struct Member {
            let identity: String
            let axis: SplitAxis
            let side: SplitBoundarySide
            let coordinate: CGFloat
            let span: ClosedRange<CGFloat>
        }

        var members: [Member] = []
        for placement in placements where placement.zone != .maximize {
            for axis in SplitAxis.allCases {
                guard let side = boundarySide(for: placement.zone, axis: axis) else {
                    continue
                }
                let span: ClosedRange<CGFloat>
                switch axis {
                case .horizontal:
                    span = placement.frame.minY...placement.frame.maxY
                case .vertical:
                    span = placement.frame.minX...placement.frame.maxX
                }
                members.append(Member(
                    identity: placement.stableIdentity,
                    axis: axis,
                    side: side,
                    coordinate: boundaryCoordinate(
                        of: placement.frame,
                        side: side,
                        axis: axis
                    ),
                    span: span
                ))
            }
        }

        var candidates: [SplitResizeHandleGeometry] = []
        let nearMembers = members.filter { $0.side == .nearOrigin }
        let farMembers = members.filter { $0.side == .farOrigin }
        for near in nearMembers {
            for far in farMembers where far.axis == near.axis {
                guard near.identity != far.identity,
                      abs(near.coordinate - far.coordinate) <= tolerance,
                      !detachedConnections.contains(
                          SplitConnectionKey(near.identity, far.identity)
                      ) else { continue }
                let lower = max(near.span.lowerBound, far.span.lowerBound)
                let upper = min(near.span.upperBound, far.span.upperBound)
                guard upper - lower > tolerance else { continue }
                candidates.append(SplitResizeHandleGeometry(
                    axis: near.axis,
                    coordinate: (near.coordinate + far.coordinate) / 2,
                    span: lower...upper,
                    participantIDs: [near.identity, far.identity]
                ))
            }
        }

        let sorted = candidates.sorted {
            if $0.axis != $1.axis {
                return $0.axis == .horizontal
            }
            if abs($0.coordinate - $1.coordinate) > mergeTolerance {
                return $0.coordinate < $1.coordinate
            }
            return $0.span.lowerBound < $1.span.lowerBound
        }
        var merged: [SplitResizeHandleGeometry] = []
        for candidate in sorted {
            guard let last = merged.last,
                  last.axis == candidate.axis,
                  abs(last.coordinate - candidate.coordinate) <= mergeTolerance,
                  candidate.span.lowerBound <= last.span.upperBound + tolerance else {
                merged.append(candidate)
                continue
            }
            let mergedLowerBound = min(
                last.span.lowerBound,
                candidate.span.lowerBound
            )
            let mergedUpperBound = max(
                last.span.upperBound,
                candidate.span.upperBound
            )
            merged[merged.count - 1] = SplitResizeHandleGeometry(
                axis: last.axis,
                coordinate: (last.coordinate + candidate.coordinate) / 2,
                span: mergedLowerBound...mergedUpperBound,
                participantIDs: last.participantIDs.union(candidate.participantIDs)
            )
        }
        return merged
    }

    static func visibleHandleSpans(
        span: ClosedRange<CGFloat>,
        axis: SplitAxis,
        coordinate: CGFloat,
        thickness: CGFloat = 16,
        occludingFrames: [CGRect],
        minimumLength: CGFloat = 12
    ) -> [ClosedRange<CGFloat>] {
        guard span.lowerBound.isFinite,
              span.upperBound.isFinite,
              span.upperBound > span.lowerBound else { return [] }
        let interactionFrame: CGRect
        switch axis {
        case .horizontal:
            interactionFrame = CGRect(
                x: coordinate - thickness / 2,
                y: span.lowerBound,
                width: thickness,
                height: span.upperBound - span.lowerBound
            )
        case .vertical:
            interactionFrame = CGRect(
                x: span.lowerBound,
                y: coordinate - thickness / 2,
                width: span.upperBound - span.lowerBound,
                height: thickness
            )
        }

        var visible: [ClosedRange<CGFloat>] = [span]
        for frame in occludingFrames where frame.intersects(interactionFrame) {
            let occludedLower = max(
                axis == .horizontal ? frame.minY : frame.minX,
                span.lowerBound
            )
            let occludedUpper = min(
                axis == .horizontal ? frame.maxY : frame.maxX,
                span.upperBound
            )
            guard occludedUpper > occludedLower else { continue }
            visible = visible.flatMap { candidate -> [ClosedRange<CGFloat>] in
                guard occludedUpper > candidate.lowerBound,
                      occludedLower < candidate.upperBound else {
                    return [candidate]
                }
                var remainder: [ClosedRange<CGFloat>] = []
                if occludedLower - candidate.lowerBound >= minimumLength {
                    remainder.append(candidate.lowerBound...occludedLower)
                }
                if candidate.upperBound - occludedUpper >= minimumLength {
                    remainder.append(occludedUpper...candidate.upperBound)
                }
                return remainder
            }
        }
        return visible.filter { $0.upperBound - $0.lowerBound >= minimumLength }
    }

    static func connectedParticipantIDs(
        startingWith identity: String,
        handles: [SplitResizeHandleGeometry]
    ) -> Set<String> {
        var connected: Set<String> = [identity]
        var didExpand = true
        while didExpand {
            didExpand = false
            for handle in handles
                where !handle.participantIDs.isDisjoint(with: connected) {
                let previousCount = connected.count
                connected.formUnion(handle.participantIDs)
                if connected.count != previousCount {
                    didExpand = true
                }
            }
        }
        return connected
    }

    static func allowedBoundaryRange(
        axis: SplitAxis,
        participants: [SplitResizeParticipantGeometry],
        screenFrame: CGRect
    ) -> ClosedRange<CGFloat>? {
        guard !participants.isEmpty else { return nil }
        var lower = axis == .horizontal ? screenFrame.minX : screenFrame.minY
        var upper = axis == .horizontal ? screenFrame.maxX : screenFrame.maxY

        for participant in participants {
            let minimum = max(participant.minimumLength, 1)
            switch (axis, participant.side) {
            case (.horizontal, .nearOrigin):
                lower = max(lower, participant.frame.minX + minimum)
            case (.horizontal, .farOrigin):
                upper = min(upper, participant.frame.maxX - minimum)
            case (.vertical, .nearOrigin):
                lower = max(lower, participant.frame.minY + minimum)
            case (.vertical, .farOrigin):
                upper = min(upper, participant.frame.maxY - minimum)
            }
        }
        guard lower <= upper else { return nil }
        return lower...upper
    }

    static func resizedFrames(
        meetingBoundary coordinate: CGFloat,
        axis: SplitAxis,
        participants: [SplitResizeParticipantGeometry]
    ) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: participants.map { participant in
            (
                participant.stableIdentity,
                frame(
                    participant.frame,
                    meetingBoundary: coordinate,
                    side: participant.side,
                    axis: axis
                )
            )
        })
    }

    static func splitAxes(for zone: SnapZone) -> Set<SplitAxis> {
        switch zone {
        case .leftHalf, .rightHalf:
            return [.horizontal]
        case .topHalf, .bottomHalf:
            return [.vertical]
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return [.horizontal, .vertical]
        case .maximize:
            return []
        }
    }

    static func boundarySide(
        for zone: SnapZone,
        axis: SplitAxis
    ) -> SplitBoundarySide? {
        switch (axis, zone) {
        case (.horizontal, .leftHalf),
             (.horizontal, .topLeft),
             (.horizontal, .bottomLeft),
             (.vertical, .bottomHalf),
             (.vertical, .bottomLeft),
             (.vertical, .bottomRight):
            return .nearOrigin

        case (.horizontal, .rightHalf),
             (.horizontal, .topRight),
             (.horizontal, .bottomRight),
             (.vertical, .topHalf),
             (.vertical, .topLeft),
             (.vertical, .topRight):
            return .farOrigin

        default:
            return nil
        }
    }

    static func perpendicularBands(
        for zone: SnapZone,
        axis: SplitAxis
    ) -> Set<SplitPerpendicularBand> {
        switch (axis, zone) {
        case (.horizontal, .topLeft), (.horizontal, .topRight),
             (.vertical, .bottomLeft), (.vertical, .topLeft):
            return [.first]

        case (.horizontal, .bottomLeft), (.horizontal, .bottomRight),
             (.vertical, .bottomRight), (.vertical, .topRight):
            return [.second]

        case (.horizontal, .leftHalf), (.horizontal, .rightHalf),
             (.vertical, .bottomHalf), (.vertical, .topHalf):
            return [.first, .second]

        default:
            return []
        }
    }

    static func boundaryCoordinate(
        of frame: CGRect,
        side: SplitBoundarySide,
        axis: SplitAxis
    ) -> CGFloat {
        switch (axis, side) {
        case (.horizontal, .nearOrigin): return frame.maxX
        case (.horizontal, .farOrigin): return frame.minX
        case (.vertical, .nearOrigin): return frame.maxY
        case (.vertical, .farOrigin): return frame.minY
        }
    }

    static func frame(
        _ frame: CGRect,
        meetingBoundary coordinate: CGFloat,
        side: SplitBoundarySide,
        axis: SplitAxis
    ) -> CGRect {
        switch (axis, side) {
        case (.horizontal, .nearOrigin):
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: max(coordinate - frame.minX, 0),
                height: frame.height
            )
        case (.horizontal, .farOrigin):
            return CGRect(
                x: coordinate,
                y: frame.minY,
                width: max(frame.maxX - coordinate, 0),
                height: frame.height
            )
        case (.vertical, .nearOrigin):
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: max(coordinate - frame.minY, 0)
            )
        case (.vertical, .farOrigin):
            return CGRect(
                x: frame.minX,
                y: coordinate,
                width: frame.width,
                height: max(frame.maxY - coordinate, 0)
            )
        }
    }

    static func hasReachedBoundary(
        initialCoordinate: CGFloat,
        currentCoordinate: CGFloat,
        participantCoordinates: [CGFloat],
        tolerance: CGFloat = contactTolerance
    ) -> Bool {
        guard !participantCoordinates.isEmpty else { return false }
        if participantCoordinates.allSatisfy({ abs($0 - initialCoordinate) <= tolerance }) {
            return true
        }

        if currentCoordinate > initialCoordinate + tolerance {
            let forward = participantCoordinates.filter { $0 > initialCoordinate + tolerance }
            guard let threshold = forward.max() else { return false }
            return currentCoordinate >= threshold - tolerance
        }
        if currentCoordinate < initialCoordinate - tolerance {
            let backward = participantCoordinates.filter { $0 < initialCoordinate - tolerance }
            guard let threshold = backward.min() else { return false }
            return currentCoordinate <= threshold + tolerance
        }
        return false
    }

    static func additionalBoundarySeparationDegree(
        initialCoordinate: CGFloat,
        currentCoordinate: CGFloat,
        participantCoordinates: [CGFloat],
        referenceLength: CGFloat
    ) -> CGFloat {
        guard !participantCoordinates.isEmpty else { return 0 }
        let initialSeparation = participantCoordinates
            .map { abs($0 - initialCoordinate) }
            .min() ?? 0
        let currentSeparation = participantCoordinates
            .map { abs($0 - currentCoordinate) }
            .min() ?? 0
        return max(currentSeparation - initialSeparation, 0) / max(referenceLength, 1)
    }

    static func framesMatchForSettlement(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func manualResizeConnectionRemainsValid(
        boundaryDegree: CGFloat,
        intrusionTolerance: CGFloat,
        outerEdgesMatch: Bool
    ) -> Bool {
        outerEdgesMatch
            && boundaryDegree.isFinite
            && intrusionTolerance.isFinite
            && boundaryDegree >= 0
            && boundaryDegree < intrusionTolerance
    }

    static func calibratedFrame(
        _ liveFrame: CGRect,
        baselineLiveFrame: CGRect,
        baselineReferenceFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: liveFrame.minX + baselineReferenceFrame.minX - baselineLiveFrame.minX,
            y: liveFrame.minY + baselineReferenceFrame.minY - baselineLiveFrame.minY,
            width: liveFrame.width + baselineReferenceFrame.width - baselineLiveFrame.width,
            height: liveFrame.height + baselineReferenceFrame.height - baselineLiveFrame.height
        )
    }

    static func resolvedFrame(
        for zone: SnapZone,
        in visibleFrame: CGRect,
        placements: [SplitPlacementGeometry],
        excluding excludedIdentity: String? = nil
    ) -> CGRect {
        guard zone != .maximize else { return visibleFrame }
        var target = zone.frame(in: visibleFrame)
        let nominal = target
        let candidates = placements.filter {
            $0.stableIdentity != excludedIdentity
                && $0.frame.width > 0
                && $0.frame.height > 0
        }

        switch zone {
        case .leftHalf, .topLeft, .bottomLeft:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .right,
                      verticalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.minX
            }
            if let boundary = boundaries.min() {
                target.size.width = max(boundary - target.minX, 1)
            }

        case .rightHalf, .topRight, .bottomRight:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .left,
                      verticalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.maxX
            }
            if let boundary = boundaries.max() {
                let right = target.maxX
                target.origin.x = min(boundary, right - 1)
                target.size.width = max(right - target.minX, 1)
            }

        case .topHalf:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .bottom,
                      horizontalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.maxY
            }
            if let boundary = boundaries.max() {
                let top = target.maxY
                target.origin.y = min(boundary, top - 1)
                target.size.height = max(top - target.minY, 1)
            }

        case .bottomHalf:
            let boundaries = candidates.compactMap { placement -> CGFloat? in
                guard relationDirection(
                    driverZone: zone,
                    followerZone: placement.zone,
                    in: visibleFrame
                ) == .top,
                      horizontalOverlap(nominal, placement.frame) > contactTolerance else { return nil }
                return placement.frame.minY
            }
            if let boundary = boundaries.min() {
                target.size.height = max(boundary - target.minY, 1)
            }

        case .maximize:
            break
        }

        return target.intersectionOrFallback(with: visibleFrame)
    }

    static func relationDirection(
        driverZone: SnapZone,
        followerZone: SnapZone,
        in visibleFrame: CGRect
    ) -> SplitRelationDirection? {
        guard driverZone != .maximize, followerZone != .maximize else { return nil }
        let driver = driverZone.frame(in: visibleFrame)
        let follower = followerZone.frame(in: visibleFrame)
        let tolerance: CGFloat = 1

        if verticalOverlap(driver, follower) > contactTolerance {
            if abs(driver.minX - follower.maxX) <= tolerance { return .left }
            if abs(driver.maxX - follower.minX) <= tolerance { return .right }
        }
        if horizontalOverlap(driver, follower) > contactTolerance {
            if abs(driver.maxY - follower.minY) <= tolerance { return .top }
            if abs(driver.minY - follower.maxY) <= tolerance { return .bottom }
        }
        return nil
    }

    static func edgeChanged(
        _ direction: SplitRelationDirection,
        from original: CGRect,
        to current: CGRect,
        tolerance: CGFloat = 1.5
    ) -> Bool {
        switch direction {
        case .left: return abs(current.minX - original.minX) > tolerance
        case .right: return abs(current.maxX - original.maxX) > tolerance
        case .top: return abs(current.maxY - original.maxY) > tolerance
        case .bottom: return abs(current.minY - original.minY) > tolerance
        }
    }

    static func signedContactMismatch(
        direction: SplitRelationDirection,
        driverFrame: CGRect,
        followerFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .left: return followerFrame.maxX - driverFrame.minX
        case .right: return driverFrame.maxX - followerFrame.minX
        case .top: return driverFrame.maxY - followerFrame.minY
        case .bottom: return followerFrame.maxY - driverFrame.minY
        }
    }

    static func hasReachedContact(initialMismatch: CGFloat, currentMismatch: CGFloat) -> Bool {
        if abs(initialMismatch) <= contactTolerance { return true }
        if initialMismatch > 0 {
            return currentMismatch <= contactTolerance
        }
        return currentMismatch >= -contactTolerance
    }

    static func followerTarget(
        direction: SplitRelationDirection,
        driverFrame: CGRect,
        followerFrame: CGRect
    ) -> CGRect {
        switch direction {
        case .left:
            return CGRect(
                x: followerFrame.minX,
                y: followerFrame.minY,
                width: max(driverFrame.minX - followerFrame.minX, 0),
                height: followerFrame.height
            )
        case .right:
            return CGRect(
                x: driverFrame.maxX,
                y: followerFrame.minY,
                width: max(followerFrame.maxX - driverFrame.maxX, 0),
                height: followerFrame.height
            )
        case .top:
            return CGRect(
                x: followerFrame.minX,
                y: driverFrame.maxY,
                width: followerFrame.width,
                height: max(followerFrame.maxY - driverFrame.maxY, 0)
            )
        case .bottom:
            return CGRect(
                x: followerFrame.minX,
                y: followerFrame.minY,
                width: followerFrame.width,
                height: max(driverFrame.minY - followerFrame.minY, 0)
            )
        }
    }

    static func invasionRatio(
        requestedLength: CGFloat,
        acceptedLength: CGFloat,
        referenceLength: CGFloat
    ) -> CGFloat {
        let reference = max(referenceLength, 1)
        let acceptedOverflow = max(acceptedLength - requestedLength, 0)
        let capacityShortage = max(reference - requestedLength, 0)
        return max(acceptedOverflow, capacityShortage) / reference
    }

    static func compressionRatio(targetLength: CGFloat, referenceLength: CGFloat) -> CGFloat {
        let reference = max(referenceLength, 1)
        return max(reference - max(targetLength, 0), 0) / reference
    }

    static func isBeyondTolerance(
        targetFrame: CGRect,
        direction: SplitRelationDirection,
        referenceSize: CGSize,
        tolerance: CGFloat
    ) -> Bool {
        let targetLength = direction.isHorizontal ? targetFrame.width : targetFrame.height
        let referenceLength = direction.isHorizontal ? referenceSize.width : referenceSize.height
        return compressionRatio(
            targetLength: targetLength,
            referenceLength: referenceLength
        ) > tolerance
    }

    static func canResume(
        targetFrame: CGRect,
        direction: SplitRelationDirection,
        referenceSize: CGSize,
        tolerance: CGFloat
    ) -> Bool {
        let resumeTolerance = max(tolerance - ratioHysteresis, 0)
        let targetLength = direction.isHorizontal ? targetFrame.width : targetFrame.height
        let referenceLength = direction.isHorizontal ? referenceSize.width : referenceSize.height
        return compressionRatio(
            targetLength: targetLength,
            referenceLength: referenceLength
        ) <= resumeTolerance
    }

    static func anchoredFrame(
        around targetFrame: CGRect,
        size: CGSize,
        anchor: CGPoint
    ) -> CGRect {
        CGRect(
            x: targetFrame.minX + (targetFrame.width - size.width) * anchor.x,
            y: targetFrame.minY + (targetFrame.height - size.height) * anchor.y,
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    static func additionalMismatchDegree(
        initialMismatch: CGFloat,
        finalMismatch: CGFloat,
        referenceLength: CGFloat
    ) -> CGFloat {
        let additional = max(abs(finalMismatch) - abs(initialMismatch), 0)
        return additional / max(referenceLength, 1)
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY), 0)
    }

    private static func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX), 0)
    }
}

private extension CGRect {
    func intersectionOrFallback(with bounds: CGRect) -> CGRect {
        let clipped = intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        }
        return clipped
    }
}
