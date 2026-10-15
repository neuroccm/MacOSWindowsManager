import XCTest
@testable import MacOSWindowsManager

final class TrellisMovesTests: XCTestCase {
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testDockZoneCenterTabsAndEdgesDock() {
        XCTAssertEqual(DockGeometry.zone(at: CGPoint(x: 600, y: 400), in: rect), .center)
        XCTAssertEqual(DockGeometry.zone(at: CGPoint(x: 10, y: 400), in: rect), .left)
        XCTAssertEqual(DockGeometry.zone(at: CGPoint(x: 1190, y: 400), in: rect), .right)
        XCTAssertEqual(DockGeometry.zone(at: CGPoint(x: 600, y: 790), in: rect), .top)
        XCTAssertEqual(DockGeometry.zone(at: CGPoint(x: 600, y: 10), in: rect), .bottom)
    }

    func testWindowEdgeDockingSplitsBesideTarget() {
        let tree = LayoutNode.leaf(id: 1).docking(2, on: 1, zone: .right)
        let f = tree.frames(in: rect, gap: 0)
        XCTAssertEqual(f.count, 2)
        XCTAssertLessThan(f[1]!.maxX, f[2]!.minX + 1)
        let top = LayoutNode.leaf(id: 1).docking(2, on: 1, zone: .top)
        XCTAssertEqual(top.frames(in: rect, gap: 0)[2]!.height, 400, accuracy: 1)
    }

    func testCenterDockCreatesTabGroupSharingOneTile() {
        let tree = LayoutNode.leaf(id: 1).docking(2, on: 1, zone: .center)
        XCTAssertEqual(Set(tree.leafIDs), [1, 2])
        let f = tree.frames(in: rect, gap: 0)
        XCTAssertEqual(f[1], f[2]) // same tile
        XCTAssertEqual(tree.activeID, 2)
    }

    func testTabCyclingAndTearOff() {
        var tree = LayoutNode.leaf(id: 1).tabbing(2, onto: 1).tabbing(3, onto: 1)
        XCTAssertEqual(tree.activeID, 3)
        tree = tree.cyclingTab(containing: 3, forward: true)
        XCTAssertEqual(tree.activeID, 1)
        let torn = tree.tearingOff(2)
        XCTAssertEqual(Set(torn.leafIDs), [1, 2, 3])
        let f = torn.frames(in: rect, gap: 0)
        XCTAssertEqual(f.count, 3)
        XCTAssertNotEqual(f[2], f[1]) // torn tab has its own tile
    }

    func testRemovingFromTabGroupCollapsesToLeaf() {
        let tree = LayoutNode.leaf(id: 1).tabbing(2, onto: 1)
        XCTAssertEqual(tree.removing(2), .leaf(id: 1))
    }

    func testSeamResizeMovesDividerAndClamps() {
        let tree = LayoutNode.leaf(id: 1).docking(2, on: 1, zone: .right)
        let grown = tree.adjustingSeam(containing: 1, delta: 0.2)
        XCTAssertEqual(grown.frames(in: rect, gap: 0)[1]!.width, 840, accuracy: 1)
        let clamped = tree.adjustingSeam(containing: 1, delta: 5)
        XCTAssertLessThanOrEqual(clamped.frames(in: rect, gap: 0)[1]!.width, 1080 + 1)
        XCTAssertFalse(tree.seamRects(in: rect, gap: 8).isEmpty)
        XCTAssertTrue(LayoutNode.leaf(id: 1).seamRects(in: rect, gap: 8).isEmpty)
    }

    func testCameraOverviewZoomBackForward() {
        var cam = CameraState(viewport: rect)
        XCTAssertTrue(cam.isOverview)
        let win = CGRect(x: 0, y: 0, width: 600, height: 800)
        cam.zoom(to: win, windowID: 7)
        XCTAssertEqual(cam.zoomedWindowID, 7)
        XCTAssertTrue(cam.goBack())
        XCTAssertTrue(cam.isOverview)
        XCTAssertTrue(cam.goForward())
        XCTAssertEqual(cam.zoomedWindowID, 7)
        cam.stepOut(displayRect: rect)
        XCTAssertTrue(cam.isOverview)
        XCTAssertEqual(CameraState.interpolated(from: rect, to: win, t: 0.5).width, 900, accuracy: 1)
    }

    func testEaseOutCubicStartsFastAndLandsSoftly() {
        XCTAssertEqual(AnimationTiming.easeOutCubic(0), 0, accuracy: 0.001)
        XCTAssertEqual(AnimationTiming.easeOutCubic(1), 1, accuracy: 0.001)
        // Halfway in time, an ease-out is well past halfway in distance.
        XCTAssertGreaterThan(AnimationTiming.easeOutCubic(0.5), 0.8)
        XCTAssertTrue(AnimationTiming.framesDiffer(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 50, y: 0, width: 100, height: 100)))
        XCTAssertFalse(AnimationTiming.framesDiffer(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0.5, y: 0, width: 100, height: 100)))
        let mid = AnimationTiming.easedFrame(from: rect, to: CGRect(x: 0, y: 0, width: 600, height: 800), t: 0.5)
        XCTAssertLessThan(mid.width, 750) // eased: closer to target than linear 900
    }

    func testSavedViewsArePerDisplay() {
        var store = SavedViewStore()
        store.save(display: "display-1", slot: 1, frames: [1: CGRect(x: 0, y: 0, width: 100, height: 100)])
        store.save(display: "display-2", slot: 1, frames: [2: CGRect(x: 500, y: 0, width: 100, height: 100)])
        XCTAssertEqual(store.frames(display: "display-1", slot: 1)?[1]?.width, 100)
        XCTAssertEqual(store.frames(display: "display-2", slot: 1)?[2]?.minX, 500)
        XCTAssertNil(store.frames(display: "display-1", slot: 2))
    }
}
