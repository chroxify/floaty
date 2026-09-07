import XCTest
@testable import Floaty

final class DockVerticalPlacementTests: XCTestCase {
    func testCenterFollowsDifferentParentAndPanelHeights() throws {
        let alignment = try XCTUnwrap(DockVerticalPlacement.alignment(
            offset: (1410 - 727) / 2, parentHeight: 1410, panelHeight: 727, gap: 8))
        XCTAssertEqual(alignment, 0.5, accuracy: 0.0001)
        for (parent, panel): (CGFloat, CGFloat) in [(800, 727), (1410, 500), (727, 727), (500, 727)] {
            let offset = DockVerticalPlacement.offset(
                alignment: alignment, parentHeight: parent, panelHeight: panel, gap: 8)
            XCTAssertEqual(offset + panel / 2, parent / 2, accuracy: 0.0001)
        }
    }

    func testTopAndBottomKeepInsets() {
        XCTAssertEqual(DockVerticalPlacement.offset(
            alignment: 0, parentHeight: 800, panelHeight: 727, gap: 8), 8)
        XCTAssertEqual(DockVerticalPlacement.offset(
            alignment: 1, parentHeight: 800, panelHeight: 727, gap: 8), 65)
    }

    func testLegacyOffsetAndDraggingRoundTrip() throws {
        let alignment = try XCTUnwrap(DockVerticalPlacement.alignment(
            offset: 431, parentHeight: 1410, panelHeight: 727, gap: 8))
        XCTAssertEqual(DockVerticalPlacement.offset(
            alignment: alignment, parentHeight: 1410, panelHeight: 727, gap: 8), 431,
            accuracy: 0.0001)
        XCTAssertEqual(DockVerticalPlacement.alignment(
            offset: -100, parentHeight: 800, panelHeight: 727, gap: 8), 0)
        XCTAssertEqual(DockVerticalPlacement.alignment(
            offset: 500, parentHeight: 800, panelHeight: 727, gap: 8), 1)
    }

    func testShortParentDoesNotOverwriteAlignment() {
        for height: CGFloat in [743, 727, 500] {
            XCTAssertNil(DockVerticalPlacement.alignment(
                offset: 8, parentHeight: height, panelHeight: 727, gap: 8))
            XCTAssertEqual(DockVerticalPlacement.offset(
                alignment: 0.8, parentHeight: height, panelHeight: 727, gap: 8),
                (height - 727) / 2)
        }
    }
}
