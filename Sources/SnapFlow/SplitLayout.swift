import AppKit

struct SplitPlacementGeometry {
    let stableIdentity: String
    let zone: SnapZone
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
    static let contactTolerance: CGFloat = 8
    static let ratioHysteresis: CGFloat = 0.05

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
