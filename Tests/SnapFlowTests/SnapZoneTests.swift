import AppKit
import XCTest
@testable import SnapFlow

final class SnapZoneTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testDetectsEdgesAndCorners() {
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 899), in: screenFrame), .topLeft)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 899), in: screenFrame), .topRight)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 1), in: screenFrame), .bottomLeft)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 1), in: screenFrame), .bottomRight)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 0, y: 450), in: screenFrame), .leftHalf)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 1_439, y: 450), in: screenFrame), .rightHalf)
        XCTAssertEqual(SnapZone.detect(at: CGPoint(x: 720, y: 899), in: screenFrame), .maximize)
        XCTAssertNil(SnapZone.detect(at: CGPoint(x: 720, y: 0), in: screenFrame))
        XCTAssertNil(SnapZone.detect(at: CGPoint(x: 720, y: 450), in: screenFrame))
    }

    func testNegativeThresholdsAreClampedToZero() {
        XCTAssertEqual(
            SnapZone.detect(
                at: CGPoint(x: 0, y: 450),
                in: screenFrame,
                edgeThreshold: -20,
                cornerBand: -20
            ),
            .leftHalf
        )
    }

    func testRequiredOuterEdges() {
        XCTAssertEqual(SnapZone.leftHalf.requiredOuterEdges, [.left, .top, .bottom])
        XCTAssertEqual(SnapZone.topRight.requiredOuterEdges, [.right, .top])
        XCTAssertEqual(SnapZone.maximize.requiredOuterEdges, .all)
    }

    func testVerticalSiblingIsSymmetric() {
        for zone in [SnapZone.topLeft, .topRight, .bottomLeft, .bottomRight] {
            XCTAssertEqual(zone.verticalSibling.verticalSibling, zone)
        }
    }

    func testRawValuesRoundTrip() throws {
        let encoded = try JSONEncoder().encode(SnapZone.allCases)
        let decoded = try JSONDecoder().decode([SnapZone].self, from: encoded)
        XCTAssertEqual(decoded, SnapZone.allCases)
    }
}
