import XCTest
@testable import MacOSWindowsManager

final class LayoutEngineTests: XCTestCase {
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testEmptyProducesNoFrames() {
        XCTAssertTrue(LayoutEngine.frames(ids: [], in: rect, gap: 8, mode: .bsp).isEmpty)
        XCTAssertNil(LayoutNode.balanced(ids: []))
    }

    func testSingleWindowFillsRectInsetByGap() {
        let f = LayoutEngine.frames(ids: [1], in: rect, gap: 10, mode: .bsp)
        XCTAssertEqual(f[1], rect.insetBy(dx: 5, dy: 5))
    }

    func testBSPTwoWindowsSplitWithoutOverlap() {
        let f = LayoutEngine.frames(ids: [1, 2], in: rect, gap: 0, mode: .bsp)
        XCTAssertEqual(f.count, 2)
        guard let a = f[1], let b = f[2] else { return XCTFail("missing frames") }
        XCTAssertFalse(a.intersects(b))
        XCTAssertEqual(a.width + b.width, rect.width, accuracy: 1)
        XCTAssertEqual(a.height, rect.height, accuracy: 1)
    }

    func testMasterStackReservesMaster() {
        let f = LayoutEngine.frames(ids: [1, 2, 3], in: rect, gap: 0, mode: .masterStack, masterRatio: 0.6)
        XCTAssertEqual(f[1]?.width ?? 0, 720, accuracy: 1)
        XCTAssertEqual(f[2]?.height ?? 0, 400, accuracy: 1)
        XCTAssertEqual(f[3]?.minY ?? 0, 400, accuracy: 1)
    }

    func testColumnsDivideEvenly() {
        let f = LayoutEngine.frames(ids: [1, 2, 3, 4], in: rect, gap: 0, mode: .columns)
        XCTAssertEqual(f.count, 4)
        for id: UInt32 in [1, 2, 3, 4] { XCTAssertEqual(f[id]?.width ?? 0, 300, accuracy: 1) }
    }

    func testTreeInsertAndRemove() {
        var tree = LayoutNode.leaf(id: 1)
        tree = tree.inserting(2)
        tree = tree.inserting(3, targetID: 2)
        XCTAssertEqual(Set(tree.leafIDs), [1, 2, 3])
        XCTAssertEqual(tree.frames(in: rect, gap: 0).count, 3)
        XCTAssertEqual(Set(tree.removing(2)?.leafIDs ?? []), [1, 3])
        XCTAssertNil(LayoutNode.leaf(id: 9).removing(9))
    }

    func testTreeDeepNestingFramesStayInsideRect() {
        guard let tree = LayoutNode.balanced(ids: [1, 2, 3, 4, 5]) else { return XCTFail("tree") }
        let frames = tree.frames(in: rect, gap: 8)
        XCTAssertEqual(frames.count, 5)
        for (_, f) in frames {
            XCTAssertTrue(rect.contains(f))
            XCTAssertGreaterThan(f.width, 0); XCTAssertGreaterThan(f.height, 0)
        }
    }

    func testCoordinateConversionRoundTrips() {
        let cocoa = CGRect(x: 100, y: 50, width: 400, height: 300)
        let ax = CoordinateConverter.axFrame(fromCocoa: cocoa, primaryHeight: 1000)
        XCTAssertEqual(ax.minY, 650, accuracy: 0.5) // 1000 - (50+300)
        XCTAssertEqual(CoordinateConverter.cocoaFrame(fromAX: ax, primaryHeight: 1000), cocoa)
    }

    func testPerDisplayIndependence() {
        // Two displays = two independent solver calls; neither affects the other.
        let left = LayoutEngine.frames(ids: [1, 2], in: CGRect(x: 0, y: 0, width: 1000, height: 700), gap: 0, mode: .bsp)
        let right = LayoutEngine.frames(ids: [3], in: CGRect(x: 1000, y: 0, width: 800, height: 600), gap: 0, mode: .bsp)
        XCTAssertEqual(left.count, 2); XCTAssertEqual(right.count, 1)
        XCTAssertEqual(right[3]?.minX, 1000)
    }

    func testGridCoversAllWindows() {
        let f = LayoutEngine.frames(ids: [1, 2, 3, 4, 5], in: rect, gap: 0, mode: .grid)
        XCTAssertEqual(f.count, 5)
    }
}
