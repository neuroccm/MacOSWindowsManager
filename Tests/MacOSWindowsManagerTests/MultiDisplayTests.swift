import XCTest
@testable import MacOSWindowsManager

/// Multi-monitor (3+) and portrait-display behaviour. Display assignment
/// must follow window overlap / proximity — never whichever display
/// happens to hold keyboard focus — and every layout must respect a
/// portrait display's orientation instead of carving it into columns.
final class MultiDisplayTests: XCTestCase {
    // Primary landscape, second landscape to the right, portrait third.
    let threeScreens = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                        CGRect(x: 4480, y: -200, width: 1080, height: 1920)]
    let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

    // MARK: - Which display owns a window

    func testWindowOnThirdPortraitDisplayIsAssignedThere() {
        let win = CGRect(x: 4600, y: 800, width: 800, height: 900)
        XCTAssertEqual(DisplayGeometry.screenIndex(forCocoaRect: win, screens: threeScreens), 2)
    }

    func testStraddlingWindowGoesToLargestOverlapNotFocus() {
        // 70% on screen 0, 30% on screen 1.
        let win = CGRect(x: 1220, y: 100, width: 1000, height: 800)
        XCTAssertEqual(DisplayGeometry.screenIndex(forCocoaRect: win, screens: threeScreens), 0)
        // Mostly on screen 1.
        let win2 = CGRect(x: 1800, y: 100, width: 1000, height: 800)
        XCTAssertEqual(DisplayGeometry.screenIndex(forCocoaRect: win2, screens: threeScreens), 1)
    }

    func testDeadZoneWindowGoesToNearestDisplay() {
        // Below the shorter primary, beside the taller second screen:
        // center is inside NO screen (mixed-height arrangement dead zone).
        let screens = [CGRect(x: 0, y: 360, width: 1920, height: 1080),
                       CGRect(x: 1920, y: 0, width: 2560, height: 1440)]
        let win = CGRect(x: 800, y: 0, width: 400, height: 300)
        XCTAssertEqual(DisplayGeometry.screenIndex(forCocoaRect: win, screens: screens), 0)
        XCTAssertEqual(DisplayGeometry.screenIndex(forCocoaPoint: CGPoint(x: 960, y: 100), screens: screens), 0)
        XCTAssertNil(DisplayGeometry.screenIndex(forCocoaRect: win, screens: []))
        XCTAssertTrue(DisplayGeometry.isPortrait(portrait))
        XCTAssertFalse(DisplayGeometry.isPortrait(threeScreens[0]))
    }

    // MARK: - Stable layout on portrait

    private func win(_ id: UInt32, _ bundle: String, _ name: String) -> StableWindowInput {
        StableWindowInput(id: id, bundleID: bundle, appName: name, isFocused: id == 1, currentFrame: .zero)
    }

    func testPortraitThreeWindowsTopHalfPlusBottomQuarters() {
        let wins = [win(1, "com.google.Chrome", "Chrome"), win(2, "com.apple.Safari", "Safari"),
                    win(3, "com.tinyspeck.slackmacgap", "Slack")]
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2, 3], in: portrait, gap: 0)
        // Primary: full-width top half (Cocoa: top has larger minY).
        XCTAssertEqual(plan.frames[1], CGRect(x: 0, y: 960, width: 1080, height: 960))
        // Bottom quarters side by side, each still readable.
        XCTAssertEqual(plan.frames[2], CGRect(x: 0, y: 0, width: 540, height: 960))
        XCTAssertEqual(plan.frames[3], CGRect(x: 540, y: 0, width: 540, height: 960))
    }

    func testThreeDisplaysPlanIndependently() {
        let wins = [win(1, "com.google.Chrome", "Chrome"), win(2, "com.apple.Safari", "Safari")]
        for screen in threeScreens {
            let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2], in: screen, gap: 8)
            XCTAssertEqual(plan.visibleCount, 2)
            for (_, f) in plan.frames { XCTAssertTrue(screen.contains(f), "\(f) outside \(screen)") }
        }
    }

    // MARK: - Legacy layouts respect portrait

    func testPortraitBalancedBSPSplitsVerticallyFirst() {
        let tree = LayoutNode.balanced(ids: [1, 2], portrait: true)!
        let f = tree.frames(in: portrait, gap: 0)
        XCTAssertEqual(f[1]?.width ?? 0, 1080, accuracy: 1)  // stacked: full width
        XCTAssertEqual(f[1]?.height ?? 0, 960, accuracy: 1)
        XCTAssertEqual(f[2]?.minY ?? -1, 960, accuracy: 1)
        // Landscape default is unchanged (side by side).
        let land = LayoutNode.balanced(ids: [1, 2])!.frames(in: CGRect(x: 0, y: 0, width: 1920, height: 1080), gap: 0)
        XCTAssertEqual(land[1]?.width ?? 0, 960, accuracy: 1)
        XCTAssertEqual(land[1]?.height ?? 0, 1080, accuracy: 1)
    }

    func testPortraitMasterStackPutsMasterOnTop() {
        let f = LayoutEngine.frames(ids: [1, 2, 3], in: portrait, gap: 0, mode: .masterStack, masterRatio: 0.6)
        XCTAssertEqual(f[1]?.width ?? 0, 1080, accuracy: 1)
        XCTAssertEqual(f[1]?.height ?? 0, 1152, accuracy: 1) // 60% of 1920
        XCTAssertEqual(f[2]?.maxY ?? 0, f[1]?.minY ?? -1, accuracy: 1) // stack below master
    }

    func testPortraitColumnsBecomeRows() {
        let f = LayoutEngine.frames(ids: [1, 2, 3], in: portrait, gap: 0, mode: .columns)
        for id: UInt32 in [1, 2, 3] { XCTAssertEqual(f[id]?.width ?? 0, 1080, accuracy: 1) }
        XCTAssertEqual(f[1]?.height ?? 0, 640, accuracy: 1)
    }

    func testGridFollowsAspectRatio() {
        let p = LayoutEngine.frames(ids: [1, 2], in: portrait, gap: 0, mode: .grid)
        XCTAssertEqual(p[1]?.width ?? 0, 1080, accuracy: 1) // one column, stacked
        let l = LayoutEngine.frames(ids: [1, 2, 3, 4], in: CGRect(x: 0, y: 0, width: 1920, height: 1080), gap: 0, mode: .grid)
        XCTAssertEqual(l[1]?.width ?? 0, 960, accuracy: 1) // 2x2 as before
    }
}
