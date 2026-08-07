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

    func testResizeHandleJoinsAFullHeightWindowToTwoQuarterWindows() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        XCTAssertEqual(handles.count, 2)
        let verticalBoundary = handles.first { $0.axis == .horizontal }
        XCTAssertEqual(verticalBoundary?.coordinate, 720)
        XCTAssertEqual(verticalBoundary?.span, 0...900)
        XCTAssertEqual(
            verticalBoundary?.participantIDs,
            Set(["left", "top-right", "bottom-right"])
        )
        let rightHorizontalBoundary = handles.first { $0.axis == .vertical }
        XCTAssertEqual(rightHorizontalBoundary?.coordinate, 450)
        XCTAssertEqual(rightHorizontalBoundary?.span, 720...1_440)
        XCTAssertEqual(
            rightHorizontalBoundary?.participantIDs,
            Set(["top-right", "bottom-right"])
        )
    }

    func testFourQuartersMergeBothBoundariesAcrossTheFullSharedSpan() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 450)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        XCTAssertEqual(handles.count, 2)
        let verticalBoundary = handles.first { $0.axis == .horizontal }
        XCTAssertEqual(verticalBoundary?.coordinate, 720)
        XCTAssertEqual(verticalBoundary?.span, 0...900)
        XCTAssertEqual(verticalBoundary?.participantIDs.count, 4)
        let horizontalBoundary = handles.first { $0.axis == .vertical }
        XCTAssertEqual(horizontalBoundary?.coordinate, 450)
        XCTAssertEqual(horizontalBoundary?.span, 0...1_440)
        XCTAssertEqual(horizontalBoundary?.participantIDs.count, 4)
    }

    func testNearlyAlignedRowsRemainIndependentUntilFramesActuallyMatch() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "top-left",
                zone: .topLeft,
                frame: CGRect(x: 0, y: 450, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-left",
                zone: .bottomLeft,
                frame: CGRect(x: 0, y: 0, width: 720, height: 450)
            ),
            SplitPlacementGeometry(
                stableIdentity: "top-right",
                zone: .topRight,
                frame: CGRect(x: 720, y: 456, width: 720, height: 444)
            ),
            SplitPlacementGeometry(
                stableIdentity: "bottom-right",
                zone: .bottomRight,
                frame: CGRect(x: 720, y: 0, width: 720, height: 456)
            )
        ]
        let handles = SplitLayoutGeometry.resizeHandleGeometries(
            placements: placements
        )
        let rowHandles = handles.filter { $0.axis == .vertical }
        XCTAssertEqual(rowHandles.count, 2)
        XCTAssertEqual(Set(rowHandles.map(\.coordinate)), Set([450, 456]))
        XCTAssertEqual(
            rowHandles.map(\.span).sorted {
                $0.lowerBound < $1.lowerBound
            },
            [0...720, 720...1_440]
        )
    }

    func testOnlyWindowsAboveAHandleParticipantCanOccludeIt() {
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 100,
                pid: 20,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 1,
                pid: 11,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 5,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 101,
                pid: 21,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 7,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 2,
                pid: 12,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 10,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 102,
                pid: 22,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                zIndex: 12,
                layer: 0
            )
        ]
        let occluders = AXWindowService().occludingWindows(
            above: [
                WindowOcclusionParticipant(
                    pid: 11,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    windowID: 1
                ),
                WindowOcclusionParticipant(
                    pid: 12,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    windowID: 2
                )
            ],
            in: snapshot
        )
        XCTAssertEqual(Set(occluders?.map(\.windowID) ?? []), Set([100, 101]))
    }

    func testOcclusionMatchingRecoversFromAStaleParticipantWindowID() {
        let leftFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let rightFrame = CGRect(x: 720, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 90,
                pid: 30,
                frame: CGRect(x: 680, y: 200, width: 300, height: 300),
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: leftFrame,
                zIndex: 3,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 20,
                pid: 12,
                frame: rightFrame,
                zIndex: 4,
                layer: 0
            )
        ]
        let occluders = AXWindowService().occludingWindows(
            above: [
                WindowOcclusionParticipant(
                    pid: 11,
                    frame: leftFrame,
                    windowID: 999
                ),
                WindowOcclusionParticipant(
                    pid: 12,
                    frame: rightFrame,
                    windowID: 20
                )
            ],
            in: snapshot
        )
        XCTAssertEqual(occluders?.map(\.windowID), [90])
    }

    func testAmbiguousParticipantMatchFailsClosed() {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: frame,
                zIndex: 2,
                layer: 0
            )
        ]
        XCTAssertNil(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: frame,
                        windowID: nil
                    )
                ],
                in: snapshot
            )
        )
    }

    func testKnownWindowIDWinsOverAmbiguousGeometry() {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: frame,
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: frame,
                zIndex: 2,
                layer: 0
            )
        ]
        XCTAssertEqual(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: frame,
                        windowID: 11
                    )
                ],
                in: snapshot
            )?.map(\.windowID),
            [10]
        )
    }

    func testReusedWindowIDWithWrongGeometryFallsBackToCurrentWindow() {
        let currentFrame = CGRect(x: 0, y: 0, width: 720, height: 900)
        let reusedIDFrame = CGRect(x: 900, y: 100, width: 300, height: 400)
        let snapshot = [
            WindowOcclusionSnapshot(
                windowID: 90,
                pid: 30,
                frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                zIndex: 1,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 11,
                frame: reusedIDFrame,
                zIndex: 2,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 11,
                frame: currentFrame,
                zIndex: 3,
                layer: 0
            )
        ]
        XCTAssertEqual(
            AXWindowService().occludingWindows(
                above: [
                    WindowOcclusionParticipant(
                        pid: 11,
                        frame: currentFrame,
                        windowID: 10
                    )
                ],
                in: snapshot
            )?.map(\.windowID),
            [90, 10]
        )
    }

    func testJunctionWaitsForIntentAndLocksToTheDominantDragAxis() {
        XCTAssertNil(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 2, y: 1)
            )
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 8, y: 3)
            ),
            .horizontal
        )
        XCTAssertEqual(
            SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: 3, y: -8)
            ),
            .vertical
        )
    }

    func testHandleInteractionFrameUsesTheEntireSharedSpan() {
        let descriptor = ResizeHandleDescriptor(
            id: "vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertEqual(
            descriptor.interactionFrame(),
            CGRect(x: 712, y: 0, width: 16, height: 900)
        )
    }

    func testUnoccludedHandleRemainsAvailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: []))
    }

    func testPartiallyOccludedHandleIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 700, y: 400, width: 40, height: 100)
        ]))
    }

    func testFullyOccludedHandleIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 700, y: -20, width: 40, height: 940)
        ]))
    }

    func testPartiallyOccludedHorizontalDividerIsEntirelyUnavailable() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:horizontal-divider",
            displayID: 1,
            axis: .vertical,
            coordinate: 450,
            span: 0...1_440,
            screenFrame: screen,
            participantIDs: ["top", "bottom"]
        )
        XCTAssertTrue(descriptor.isOccluded(by: [
            CGRect(x: 600, y: 430, width: 240, height: 40)
        ]))
    }

    func testWindowTouchingOnlyTheInteractionFrameEdgeDoesNotHideHandle() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: [
            CGRect(x: 728, y: 400, width: 100, height: 100)
        ]))
    }

    func testWindowAwayFromHandleDoesNotHideIt() {
        let descriptor = ResizeHandleDescriptor(
            id: "display:1:vertical-divider",
            displayID: 1,
            axis: .horizontal,
            coordinate: 720,
            span: 0...900,
            screenFrame: screen,
            participantIDs: ["left", "right"]
        )
        XCTAssertFalse(descriptor.isOccluded(by: [
            CGRect(x: 900, y: 400, width: 40, height: 100)
        ]))
    }

    func testConnectedParticipantIDsIncludeTheWholeSplitGroupOnly() {
        let handles = [
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 720,
                span: 0...900,
                participantIDs: ["main", "right-top", "right-bottom"]
            ),
            SplitResizeHandleGeometry(
                axis: .vertical,
                coordinate: 450,
                span: 720...1_440,
                participantIDs: ["right-top", "right-bottom"]
            ),
            SplitResizeHandleGeometry(
                axis: .horizontal,
                coordinate: 200,
                span: 0...300,
                participantIDs: ["unrelated-a", "unrelated-b"]
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.connectedParticipantIDs(
                startingWith: "main",
                handles: handles
            ),
            Set(["main", "right-top", "right-bottom"])
        )
    }

    func testRecoverableResizeUsesHysteresisBeforeReconnecting() {
        XCTAssertTrue(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: false,
                compressionRatios: [0.51],
                tolerance: 0.5
            )
        )
        XCTAssertTrue(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: true,
                compressionRatios: [0.47],
                tolerance: 0.5
            )
        )
        XCTAssertFalse(
            SplitLayoutGeometry.remainsSuspended(
                wasSuspended: true,
                compressionRatios: [0.44],
                tolerance: 0.5
            )
        )
    }

    func testResizeHandleDoesNotJoinDetachedWindows() {
        let placements = [
            SplitPlacementGeometry(
                stableIdentity: "left",
                zone: .leftHalf,
                frame: CGRect(x: 0, y: 0, width: 720, height: 900)
            ),
            SplitPlacementGeometry(
                stableIdentity: "right",
                zone: .rightHalf,
                frame: CGRect(x: 720, y: 0, width: 720, height: 900)
            )
        ]
        XCTAssertTrue(
            SplitLayoutGeometry.resizeHandleGeometries(
                placements: placements,
                detachedConnections: [SplitConnectionKey("left", "right")]
            ).isEmpty
        )
    }

    func testAllowedBoundaryRangeProtectsBothSides() {
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                side: .nearOrigin,
                minimumLength: 300
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right",
                frame: CGRect(x: 720, y: 0, width: 720, height: 900),
                side: .farOrigin,
                minimumLength: 400
            )
        ]
        XCTAssertEqual(
            SplitLayoutGeometry.allowedBoundaryRange(
                axis: .horizontal,
                participants: participants,
                screenFrame: screen
            ),
            300...1_040
        )
    }

    func testHandleResizeUsesOneBoundaryForEveryParticipant() {
        let participants = [
            SplitResizeParticipantGeometry(
                stableIdentity: "left",
                frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                side: .nearOrigin,
                minimumLength: 1
            ),
            SplitResizeParticipantGeometry(
                stableIdentity: "right",
                frame: CGRect(x: 720, y: 0, width: 720, height: 900),
                side: .farOrigin,
                minimumLength: 1
            )
        ]
        let frames = SplitLayoutGeometry.resizedFrames(
            meetingBoundary: 840,
            axis: .horizontal,
            participants: participants
        )
        XCTAssertEqual(frames["left"]?.maxX, 840)
        XCTAssertEqual(frames["right"]?.minX, 840)
        XCTAssertEqual(frames["left"]?.minX, screen.minX)
        XCTAssertEqual(frames["right"]?.maxX, screen.maxX)
    }

    func testConnectedGroupNeedsRaiseWhenExternalWindowSeparatesMembers() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 100, y: 100, width: 200, height: 200)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testConnectedGroupIsFrontmostWhenAllMembersLeadRelevantWindows() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 100, y: 100, width: 800, height: 200)
            )
        ]
        XCTAssertTrue(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testConnectedGroupIgnoresWindowsOutsideItsCombinedBounds() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "external-display",
                frame: CGRect(x: 2_000, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertTrue(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testConnectedGroupIsNotFrontmostWhenAMemberIsMissing() {
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "missing-group"],
            orderedWindows: [
                SplitZOrderWindow(
                    stableIdentity: "front-group",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 900)
                )
            ]
        ))
    }

    func testConnectedGroupNeedsRaiseWhenExternalWindowOccludesRearMember() {
        let windows = [
            SplitZOrderWindow(
                stableIdentity: "front-group",
                frame: CGRect(x: 0, y: 0, width: 500, height: 900)
            ),
            SplitZOrderWindow(
                stableIdentity: "external",
                frame: CGRect(x: 600, y: 100, width: 200, height: 200)
            ),
            SplitZOrderWindow(
                stableIdentity: "rear-group",
                frame: CGRect(x: 500, y: 0, width: 500, height: 900)
            )
        ]
        XCTAssertFalse(SplitLayoutGeometry.connectedGroupIsFrontmost(
            groupIDs: ["front-group", "rear-group"],
            orderedWindows: windows
        ))
    }

    func testRecoverySceneSignatureIgnoresNonWindowLayers() {
        let windows = [
            WindowOcclusionSnapshot(
                windowID: 10,
                pid: 100,
                frame: CGRect(x: 0, y: 0, width: 500, height: 900),
                zIndex: 0,
                layer: 0
            ),
            WindowOcclusionSnapshot(
                windowID: 11,
                pid: 101,
                frame: CGRect(x: 500, y: 0, width: 500, height: 900),
                zIndex: 1,
                layer: 0
            )
        ]
        let withMenu = [
            WindowOcclusionSnapshot(
                windowID: 99,
                pid: 200,
                frame: CGRect(x: 20, y: 20, width: 100, height: 40),
                zIndex: 0,
                layer: 24
            )
        ] + windows

        XCTAssertEqual(
            SplitLayoutGeometry.recoverySceneSignature(for: windows),
            SplitLayoutGeometry.recoverySceneSignature(for: withMenu)
        )
    }

    func testRecoverySceneSignatureChangesForWindowOrderOrGeometry() {
        let first = WindowOcclusionSnapshot(
            windowID: 10,
            pid: 100,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900),
            zIndex: 0,
            layer: 0
        )
        let second = WindowOcclusionSnapshot(
            windowID: 11,
            pid: 101,
            frame: CGRect(x: 500, y: 0, width: 500, height: 900),
            zIndex: 1,
            layer: 0
        )
        let movedSecond = WindowOcclusionSnapshot(
            windowID: 11,
            pid: 101,
            frame: CGRect(x: 520, y: 0, width: 480, height: 900),
            zIndex: 1,
            layer: 0
        )
        let originalSignature = SplitLayoutGeometry.recoverySceneSignature(
            for: [first, second]
        )

        XCTAssertNotEqual(
            originalSignature,
            SplitLayoutGeometry.recoverySceneSignature(for: [second, first])
        )
        XCTAssertNotEqual(
            originalSignature,
            SplitLayoutGeometry.recoverySceneSignature(
                for: [first, movedSecond]
            )
        )
    }

    func testFocusedWindowPollEstablishesBaselineWithoutTriggering() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:first",
            mainIdentity: "ax:100:first"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertTrue(state.hasBaseline)
        XCTAssertEqual(state.lastSnapshot, first)
        XCTAssertNil(state.observe(first))
    }

    func testFocusedWindowPollPrefersAChangedMainWindow() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:first-main"
        )
        let second = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:second-main"
        )
        let expected = FocusedWindowIdentity(
            pid: 100,
            stableIdentity: "ax:100:second-main"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), expected)
        XCTAssertNil(state.observe(second))
    }

    func testFocusedWindowPollUsesFocusedChangeWhenMainIsStable() {
        var state = FocusedWindowPollState()
        let first = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:first-focused",
            mainIdentity: "ax:100:main"
        )
        let second = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:second-focused",
            mainIdentity: "ax:100:main"
        )

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(
            state.observe(second),
            FocusedWindowIdentity(
                pid: 100,
                stableIdentity: "ax:100:second-focused"
            )
        )
    }

    func testFocusedWindowPollRecoversAfterTemporaryNil() {
        var state = FocusedWindowPollState()
        let window = ActiveWindowIdentitySnapshot(
            pid: 100,
            focusedIdentity: "ax:100:focused",
            mainIdentity: "ax:100:main"
        )
        let expected = FocusedWindowIdentity(
            pid: 100,
            stableIdentity: "ax:100:main"
        )

        XCTAssertNil(state.observe(window))
        XCTAssertNil(state.observe(nil))
        XCTAssertEqual(state.observe(window), expected)
        state.reset()
        XCTAssertFalse(state.hasBaseline)
        XCTAssertNil(state.lastSnapshot)
        XCTAssertNil(state.observe(window))
    }

    func testFocusedWindowSettlementRequiresConsecutiveIdentitySamples() {
        let first = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: nil,
            currentIdentity: "window-a",
            previousCount: 0
        )
        let second = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: "window-a",
            currentIdentity: "window-a",
            previousCount: first
        )
        let third = FocusedWindowSettlementState.nextObservationCount(
            previousIdentity: "window-a",
            currentIdentity: "window-a",
            previousCount: second
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
    }

    func testFocusedWindowSettlementResetsWhenCandidateChangesOrDisappears() {
        XCTAssertEqual(
            FocusedWindowSettlementState.nextObservationCount(
                previousIdentity: "window-a",
                currentIdentity: "window-b",
                previousCount: 2
            ),
            1
        )
        XCTAssertEqual(
            FocusedWindowSettlementState.nextObservationCount(
                previousIdentity: "window-a",
                currentIdentity: nil,
                previousCount: 2
            ),
            0
        )
    }

    func testWindowServerSelectionPollEstablishesBaselineWithoutTriggering() {
        var state = WindowServerSelectionPollState()
        let selection = WindowServerSelectionSnapshot(
            pid: 100,
            windowID: 42
        )

        XCTAssertNil(state.observe(selection))
        XCTAssertEqual(state.lastSnapshot, selection)
        XCTAssertNil(state.observe(selection))
    }

    func testWindowServerSelectionPollReportsExactWindowChange() {
        var state = WindowServerSelectionPollState()
        let first = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let second = WindowServerSelectionSnapshot(pid: 100, windowID: 43)

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), second)
        XCTAssertNil(state.observe(second))
    }

    func testWindowServerSelectionPollReportsApplicationChange() {
        var state = WindowServerSelectionPollState()
        let first = WindowServerSelectionSnapshot(pid: 100, windowID: 42)
        let second = WindowServerSelectionSnapshot(pid: 200, windowID: 84)

        XCTAssertNil(state.observe(first))
        XCTAssertEqual(state.observe(second), second)
    }

    func testWindowServerSelectionPollRecoversAfterMissionControlGap() {
        var state = WindowServerSelectionPollState()
        let selection = WindowServerSelectionSnapshot(pid: 100, windowID: 42)

        XCTAssertNil(state.observe(selection))
        XCTAssertNil(state.observe(nil))
        XCTAssertEqual(state.observe(selection), selection)
    }
}
