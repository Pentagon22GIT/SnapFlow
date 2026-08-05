import AppKit
import XCTest
@testable import SnapFlow

final class SplitLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testOppositeSnapUsesRemainingFortyPercent() {
        let left = SplitPlacementGeometry(
            stableIdentity: "left",
            zone: .leftHalf,
            frame: CGRect(x: 0, y: 0, width: 864, height: 900)
        )
        let result = SplitLayoutGeometry.resolvedFrame(
            for: .rightHalf,
            in: screen,
            placements: [left]
        )
        XCTAssertEqual(result, CGRect(x: 864, y: 0, width: 576, height: 900))
    }

    func testFullHeightSnapUsesSafeBoundaryAcrossDiscontinuousRows() {
        let topLeft = SplitPlacementGeometry(
            stableIdentity: "top-left",
            zone: .topLeft,
            frame: CGRect(x: 0, y: 450, width: 864, height: 450)
        )
        let bottomLeft = SplitPlacementGeometry(
            stableIdentity: "bottom-left",
            zone: .bottomLeft,
            frame: CGRect(x: 0, y: 0, width: 720, height: 450)
        )
        let result = SplitLayoutGeometry.resolvedFrame(
            for: .rightHalf,
            in: screen,
            placements: [topLeft, bottomLeft]
        )
        XCTAssertEqual(result.minX, 864)
        XCTAssertEqual(result.maxX, screen.maxX)
    }

    func testQuarterRelationsOnlyLinkTheSharedFace() {
        XCTAssertEqual(
            SplitLayoutGeometry.relationDirection(
                driverZone: .topLeft,
                followerZone: .topRight,
                in: screen
            ),
            .right
        )
        XCTAssertNil(
            SplitLayoutGeometry.relationDirection(
                driverZone: .topLeft,
                followerZone: .bottomRight,
                in: screen
            )
        )
    }

    func testQuarterSnapDeclaresBothBoundaryAxes() {
        XCTAssertEqual(
            SplitLayoutGeometry.splitAxes(for: .topLeft),
            Set([.horizontal, .vertical])
        )
        XCTAssertEqual(
            SplitLayoutGeometry.splitAxes(for: .rightHalf),
            Set([.horizontal])
        )
    }

    func testQuarterZonesJoinTheSameVerticalBoundaryFromOppositeSides() {
        XCTAssertEqual(
            SplitLayoutGeometry.boundarySide(for: .topLeft, axis: .horizontal),
            .nearOrigin
        )
        XCTAssertEqual(
            SplitLayoutGeometry.boundarySide(for: .bottomRight, axis: .horizontal),
            .farOrigin
        )
        XCTAssertEqual(
            SplitLayoutGeometry.perpendicularBands(for: .topLeft, axis: .horizontal),
            Set([.first])
        )
        XCTAssertEqual(
            SplitLayoutGeometry.perpendicularBands(for: .bottomLeft, axis: .horizontal),
            Set([.second])
        )
    }

    func testUnevenRowJoinsOnlyAfterDriverCatchesItsBoundary() {
        XCTAssertFalse(
            SplitLayoutGeometry.hasReachedBoundary(
                initialCoordinate: 600,
                currentCoordinate: 740,
                participantCoordinates: [800, 800]
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.hasReachedBoundary(
                initialCoordinate: 600,
                currentCoordinate: 792,
                participantCoordinates: [800, 800]
            )
        )
    }

    func testJoinedVerticalBoundaryResizesBothSidesToOneCoordinate() {
        let left = SplitLayoutGeometry.frame(
            CGRect(x: 0, y: 0, width: 720, height: 450),
            meetingBoundary: 840,
            side: .nearOrigin,
            axis: .horizontal
        )
        let right = SplitLayoutGeometry.frame(
            CGRect(x: 720, y: 0, width: 720, height: 450),
            meetingBoundary: 840,
            side: .farOrigin,
            axis: .horizontal
        )
        XCTAssertEqual(left.maxX, 840)
        XCTAssertEqual(right.minX, 840)
        XCTAssertEqual(right.maxX, 1_440)
    }

    func testMouseUpSettlementRequiresSubpointFrameStability() {
        let first = CGRect(x: 0, y: 0, width: 720, height: 450)
        XCTAssertTrue(
            SplitLayoutGeometry.framesMatchForSettlement(
                first,
                CGRect(x: 0.4, y: 0, width: 720.4, height: 450)
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.framesMatchForSettlement(
                first,
                CGRect(x: 1, y: 0, width: 721, height: 450)
            )
        )
    }

    func testWindowServerFrameKeepsTheAccessibilityBaseline() {
        let serverBaseline = CGRect(x: 1, y: 1, width: 718, height: 448)
        let accessibilityBaseline = CGRect(x: 0, y: 0, width: 720, height: 450)
        let liveServerFrame = CGRect(x: 1, y: 1, width: 838, height: 448)
        XCTAssertEqual(
            SplitLayoutGeometry.calibratedFrame(
                liveServerFrame,
                baselineLiveFrame: serverBaseline,
                baselineReferenceFrame: accessibilityBaseline
            ),
            CGRect(x: 0, y: 0, width: 840, height: 450)
        )
    }

    func testExistingOverlapWaitsUntilActualContact() {
        XCTAssertFalse(
            SplitLayoutGeometry.hasReachedContact(
                initialMismatch: 60,
                currentMismatch: 30
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.hasReachedContact(
                initialMismatch: 60,
                currentMismatch: 8
            )
        )
    }

    func testFollowerKeepsItsFarEdge() {
        let follower = CGRect(x: 720, y: 0, width: 720, height: 900)
        let driver = CGRect(x: 0, y: 0, width: 900, height: 900)
        let target = SplitLayoutGeometry.followerTarget(
            direction: .right,
            driverFrame: driver,
            followerFrame: follower
        )
        XCTAssertEqual(target.minX, 900)
        XCTAssertEqual(target.maxX, 1_440)
    }

    func testConstraintHintLearnsAnAcceptedMinimumWithoutUsingScreenPoints() {
        var hint = WindowConstraintHint()
        hint.observe(
            requested: CGSize(width: 240, height: 300),
            accepted: CGSize(width: 600, height: 300)
        )
        let reference = hint.referenceSize(
            current: CGSize(width: 900, height: 700),
            nominal: CGSize(width: 720, height: 450)
        )
        XCTAssertEqual(reference.width, 600)
        XCTAssertEqual(reference.height, 450)
    }

    func testUnobservedConstraintUsesWindowAndNominalGeometry() {
        let reference = WindowConstraintHint().referenceSize(
            current: CGSize(width: 900, height: 300),
            nominal: CGSize(width: 720, height: 450)
        )
        XCTAssertEqual(reference, CGSize(width: 720, height: 300))
    }

    func testNewSplitInvasionUsesTheCandidateConstraintReference() {
        XCTAssertEqual(
            SplitLayoutGeometry.invasionRatio(
                requestedLength: 300,
                acceptedLength: 600,
                referenceLength: 600
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            SplitLayoutGeometry.invasionRatio(
                requestedLength: 144,
                acceptedLength: 144,
                referenceLength: 720
            ),
            0.5
        )
    }

    func testRatioHysteresisPreventsVirtualBoxFlicker() {
        let reference = CGSize(width: 600, height: 400)
        XCTAssertTrue(
            SplitLayoutGeometry.isBeyondTolerance(
                targetFrame: CGRect(x: 0, y: 0, width: 290, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.canResume(
                targetFrame: CGRect(x: 0, y: 0, width: 320, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.canResume(
                targetFrame: CGRect(x: 0, y: 0, width: 340, height: 400),
                direction: .right,
                referenceSize: reference,
                tolerance: 0.5
            )
        )
    }

    func testManualResizeConnectionRequiresOuterEdgesToRemainAnchored() {
        XCTAssertTrue(
            SplitLayoutGeometry.manualResizeConnectionRemainsValid(
                boundaryDegree: 0.02,
                intrusionTolerance: 0.5,
                outerEdgesMatch: true
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.manualResizeConnectionRemainsValid(
                boundaryDegree: 0.02,
                intrusionTolerance: 0.5,
                outerEdgesMatch: false
            )
        )
    }

    func testManualResizeConnectionRejectsInvalidOrExcessiveDegrees() {
        XCTAssertFalse(
            SplitLayoutGeometry.manualResizeConnectionRemainsValid(
                boundaryDegree: 0.5,
                intrusionTolerance: 0.5,
                outerEdgesMatch: true
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.manualResizeConnectionRemainsValid(
                boundaryDegree: .nan,
                intrusionTolerance: 0.5,
                outerEdgesMatch: true
            )
        )
    }
}
