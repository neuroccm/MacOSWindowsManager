import XCTest
@testable import MacOSWindowsManager

/// Locks in the "no bonkers layouts" contract: per display the automatic
/// arranger only ever produces full / halves / half+2 quarters / quarters,
/// pairs similar apps side by side, and never moves a window unless the
/// window *set* changed.
final class StableLayoutTests: XCTestCase {
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 1000) // quarter = 800x500

    private func win(_ id: UInt32, _ bundle: String, _ name: String, focused: Bool = false) -> StableWindowInput {
        StableWindowInput(id: id, bundleID: bundle, appName: name, isFocused: focused, currentFrame: .zero)
    }

    // MARK: - Classification / pairing

    func testClassifierPairsSimilarApps() {
        XCTAssertEqual(AppClassifier.category(bundleID: "com.google.Chrome", appName: "Google Chrome"), .browser)
        XCTAssertEqual(AppClassifier.category(bundleID: "com.apple.Safari", appName: "Safari"), .browser)
        XCTAssertEqual(AppClassifier.category(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"), .messaging)
        XCTAssertEqual(AppClassifier.category(bundleID: "com.microsoft.VSCode", appName: "Code"), .code)
        XCTAssertEqual(AppClassifier.category(bundleID: "com.apple.Terminal", appName: "Terminal"), .terminal)
        XCTAssertTrue(AppClassifier.areSimilar(bundleA: "com.google.Chrome", nameA: "Chrome",
                                               bundleB: "com.apple.Safari", nameB: "Safari"))
        XCTAssertTrue(AppClassifier.areSimilar(bundleA: "com.example.Foo", nameA: "Foo",
                                               bundleB: "com.example.Foo", nameB: "Foo"))
        XCTAssertFalse(AppClassifier.areSimilar(bundleA: "com.google.Chrome", nameA: "Chrome",
                                                bundleB: "com.tinyspeck.slackmacgap", nameB: "Slack"))
    }

    // MARK: - Slot templates: only halves & quarters

    func testTwoWindowsAreHalves() {
        let a = win(1, "com.google.Chrome", "Chrome", focused: true)
        let b = win(2, "com.apple.Safari", "Safari")
        let plan = StableLayout.plan(windows: [a, b], previousOrder: [], in: rect, gap: 0)
        XCTAssertEqual(plan.visibleCount, 2)
        XCTAssertEqual(plan.frames[1]?.width ?? 0, 800, accuracy: 1)
        XCTAssertEqual(plan.frames[1]?.height ?? 0, 1000, accuracy: 1)
        XCTAssertEqual(plan.frames[2]?.minX ?? 0, 800, accuracy: 1)
    }

    func testFreshLayoutPutsFocusedFirstAndGroupsSimilars() {
        // Focused browser listed last still becomes the primary (left half),
        // the other browser pairs next to it, messaging comes last.
        let slack = win(3, "com.tinyspeck.slackmacgap", "Slack")
        let chrome = win(1, "com.google.Chrome", "Chrome")
        let safari = win(2, "com.apple.Safari", "Safari", focused: true)
        let plan = StableLayout.plan(windows: [slack, chrome, safari], previousOrder: [], in: rect, gap: 0)
        XCTAssertEqual(plan.orderedIDs, [2, 1, 3])
        XCTAssertEqual(plan.frames[2]?.width ?? 0, 800, accuracy: 1) // primary: full half
    }

    func testFourWindowsAreQuartersInReadingOrder() {
        let wins = (1...4).map { win(UInt32($0), "com.example.\($0)", "App\($0)") }
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2, 3, 4], in: rect, gap: 0)
        XCTAssertEqual(plan.visibleCount, 4)
        for id: UInt32 in 1...4 {
            XCTAssertEqual(plan.frames[id]?.width ?? 0, 800, accuracy: 1)
            XCTAssertEqual(plan.frames[id]?.height ?? 0, 500, accuracy: 1)
        }
        // Reading order in Cocoa coords: TL, TR, BL, BR (top row has larger minY).
        XCTAssertEqual(plan.frames[1]?.minY ?? 0, 500, accuracy: 1)
        XCTAssertEqual(plan.frames[2]?.minX ?? 0, 800, accuracy: 1)
        XCTAssertEqual(plan.frames[4]?.minY ?? 0, 0, accuracy: 1)
    }

    // MARK: - The user's scenario

    func testMessagingArrivalKeepsPrimaryBrowserAtHalf() {
        // Two browsers side by side; a messaging window opens.
        let chrome = win(1, "com.google.Chrome", "Chrome", focused: true)
        let safari = win(2, "com.apple.Safari", "Safari")
        let slack = win(3, "com.tinyspeck.slackmacgap", "Slack")
        let plan = StableLayout.plan(windows: [chrome, safari, slack], previousOrder: [1, 2], in: rect, gap: 0)
        XCTAssertEqual(plan.orderedIDs, [1, 2, 3])
        // Primary browser: still the full left half, untouched position.
        XCTAssertEqual(plan.frames[1], CGRect(x: 0, y: 0, width: 800, height: 1000))
        // Second browser shrinks in place to the top-right quarter.
        XCTAssertEqual(plan.frames[2], CGRect(x: 800, y: 500, width: 800, height: 500))
        // Messaging newcomer: bottom-right quarter.
        XCTAssertEqual(plan.frames[3], CGRect(x: 800, y: 0, width: 800, height: 500))
    }

    func testSimilarNewcomerSwapsInBesidePrimary() {
        // Browser (primary) + Word on screen; a second browser opens.
        // One bounded swap pairs the browsers; Word drops to the last slot.
        let chrome = win(1, "com.google.Chrome", "Chrome", focused: true)
        let word = win(2, "com.microsoft.Word", "Word")
        let safari = win(3, "com.apple.Safari", "Safari")
        let plan = StableLayout.plan(windows: [chrome, word, safari], previousOrder: [1, 2], in: rect, gap: 0)
        XCTAssertEqual(plan.orderedIDs, [1, 3, 2])
        XCTAssertEqual(plan.frames[3], CGRect(x: 800, y: 500, width: 800, height: 500)) // beside primary
        XCTAssertEqual(plan.frames[1], CGRect(x: 0, y: 0, width: 800, height: 1000))    // primary never moves
    }

    // MARK: - Overflow tabs instead of subdividing

    func testFifthWindowTabsBehindSimilarInsteadOfSplittingFurther() {
        let wins = [win(1, "com.google.Chrome", "Chrome", focused: true),
                    win(2, "com.apple.Safari", "Safari"),
                    win(3, "com.microsoft.Word", "Word"),
                    win(4, "com.apple.mail", "Mail"),
                    win(5, "org.mozilla.firefox", "Firefox")]
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2, 3, 4, 5], in: rect, gap: 0)
        XCTAssertEqual(plan.visibleCount, 4)
        XCTAssertNotNil(plan.tabbedBehind[5])
        let host = plan.tabbedBehind[5]!
        XCTAssertTrue(host == 1 || host == 2, "5th browser should tab behind a browser, got \(host)")
        XCTAssertEqual(plan.frames[5], plan.frames[host]) // shares the host tile
        // Nothing is smaller than a quarter.
        for (id, f) in plan.frames where plan.tabbedBehind[id] == nil {
            XCTAssertGreaterThanOrEqual(f.width, 800 - 1)
            XCTAssertGreaterThanOrEqual(f.height, 500 - 1)
        }
    }

    // MARK: - Stability: the anti-bonkers guarantees

    func testFocusChangeAloneMovesNothing() {
        let base = [win(1, "com.google.Chrome", "Chrome", focused: true),
                    win(2, "com.apple.Safari", "Safari"),
                    win(3, "com.tinyspeck.slackmacgap", "Slack")]
        let p1 = StableLayout.plan(windows: base, previousOrder: [1, 2, 3], in: rect, gap: 8)
        // Same set, focus now on Slack (user merely clicked it).
        let refocused = [win(1, "com.google.Chrome", "Chrome"),
                         win(2, "com.apple.Safari", "Safari"),
                         win(3, "com.tinyspeck.slackmacgap", "Slack", focused: true)]
        let p2 = StableLayout.plan(windows: refocused, previousOrder: p1.orderedIDs, in: rect, gap: 8)
        XCTAssertEqual(p1.frames, p2.frames)
        XCTAssertEqual(p1.orderedIDs, p2.orderedIDs)
    }

    func testClosingWindowPromotesTabbedAndKeepsEveryoneElseInPlace() {
        let wins5 = (1...5).map { win(UInt32($0), "com.example.\($0)", "App\($0)") }
        let before = StableLayout.plan(windows: wins5, previousOrder: [1, 2, 3, 4, 5], in: rect, gap: 0)
        XCTAssertEqual(before.visibleCount, 4)
        // Window 2 (top-right) closes; tabbed window 5 takes its slot.
        let after = StableLayout.plan(windows: wins5.filter { $0.id != 2 },
                                      previousOrder: before.orderedIDs, in: rect, gap: 0)
        XCTAssertEqual(after.orderedIDs, [1, 3, 4, 5])
        XCTAssertEqual(after.frames[1], before.frames[1]) // slot 0 pixel-identical
        XCTAssertEqual(after.frames[5], before.frames[4]) // promoted into the tail slot
        XCTAssertNil(after.tabbedBehind[5])
    }

    func testShrinkingFromThreeToTwoRestoresHalves() {
        let wins = [win(1, "com.google.Chrome", "Chrome"), win(3, "com.tinyspeck.slackmacgap", "Slack")]
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2, 3], in: rect, gap: 0)
        XCTAssertEqual(plan.orderedIDs, [1, 3])
        XCTAssertEqual(plan.frames[3], CGRect(x: 800, y: 0, width: 800, height: 1000)) // back to a full half
    }

    // MARK: - Small / portrait displays

    func testSmallDisplayCapsAtHalves() {
        let small = CGRect(x: 0, y: 0, width: 900, height: 560) // quarter would be 450x280: unreadable
        XCTAssertEqual(StableLayout.maxVisible(in: small), 2)
        let wins = (1...4).map { win(UInt32($0), "com.example.\($0)", "App\($0)") }
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2, 3, 4], in: small, gap: 0)
        XCTAssertEqual(plan.visibleCount, 2)
        XCTAssertEqual(plan.tabbedBehind.count, 2)
    }

    func testPortraitDisplayStacksHalves() {
        let portrait = CGRect(x: 0, y: 0, width: 900, height: 1400)
        XCTAssertEqual(StableLayout.maxVisible(in: portrait), 4)
        let wins = [win(1, "com.example.1", "A"), win(2, "com.example.2", "B")]
        let plan = StableLayout.plan(windows: wins, previousOrder: [1, 2], in: portrait, gap: 0)
        XCTAssertEqual(plan.frames[1]?.height ?? 0, 700, accuracy: 1) // top half
        XCTAssertEqual(plan.frames[1]?.width ?? 0, 900, accuracy: 1)
        XCTAssertEqual(plan.frames[2]?.minY ?? -1, 0, accuracy: 1)    // bottom half
    }
}
