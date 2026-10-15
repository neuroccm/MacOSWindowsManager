import CoreGraphics
import Foundation

/// Camera for one display: the viewport you are looking at.
/// `viewport == displayRect` is the overview (see everything); a window-sized
/// viewport is zoomed into that window. Pure value type — fully unit-tested.
public struct CameraState: Equatable {
    public var viewport: CGRect
    public var zoomedWindowID: UInt32?
    public private(set) var backStack: [CGRect] = []
    public private(set) var forwardStack: [CGRect] = []
    public private(set) var zoomBackStack: [UInt32?] = []
    public private(set) var zoomForwardStack: [UInt32?] = []

    public init(viewport: CGRect, zoomedWindowID: UInt32? = nil) {
        self.viewport = viewport; self.zoomedWindowID = zoomedWindowID
    }

    public var isOverview: Bool { zoomedWindowID == nil }

    public mutating func showOverview(displayRect: CGRect) {
        pushHistory(); viewport = displayRect; zoomedWindowID = nil
    }

    public mutating func zoom(to frame: CGRect, windowID: UInt32) {
        pushHistory(); viewport = frame; zoomedWindowID = windowID
    }

    /// Step out one level: back to the overview of the whole display.
    public mutating func stepOut(displayRect: CGRect) { showOverview(displayRect: displayRect) }

    private mutating func pushHistory() {
        backStack.append(viewport); zoomBackStack.append(zoomedWindowID)
        forwardStack.removeAll(); zoomForwardStack.removeAll()
        // Long sessions zooming around must not grow history without bound.
        if backStack.count > 32 {
            backStack.removeFirst(backStack.count - 32)
            zoomBackStack.removeFirst(zoomBackStack.count - 32)
        }
    }

    public mutating func goBack() -> Bool {
        guard let prev = backStack.popLast() else { return false }
        forwardStack.append(viewport); zoomForwardStack.append(zoomedWindowID)
        viewport = prev; zoomedWindowID = zoomBackStack.popLast() ?? nil
        return true
    }

    public mutating func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(viewport); zoomBackStack.append(zoomedWindowID)
        viewport = next; zoomedWindowID = zoomForwardStack.popLast() ?? nil
        return true
    }

    /// Interpolated viewport for the single 460ms layout motion.
    public static func interpolated(from a: CGRect, to b: CGRect, t: Double) -> CGRect {
        let t = min(max(t, 0), 1)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

/// Shared motion timing: deadline-paced 60fps ease-out (see TilingManager.apply).
public enum AnimationTiming {
    public static let duration: Double = 0.36
    public static let frameInterval: Double = 1.0 / 60.0
    /// Fast start, gentle landing — most perceived smoothness comes from easing.
    public static func easeOutCubic(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
    public static func easedFrame(from a: CGRect, to b: CGRect, t: Double) -> CGRect {
        CameraState.interpolated(from: a, to: b, t: easeOutCubic(t))
    }
    public static func framesDiffer(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance ||
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }
}

/// Saved views are per display: display key -> slot -> AX frames.
public struct SavedViewStore: Equatable {
    public var byDisplay: [String: [Int: [UInt32: CodableRect]]] = [:]
    public init() {}
    public mutating func save(display: String, slot: Int, frames: [UInt32: CGRect]) {
        byDisplay[display, default: [:]][slot] = frames.mapValues { CodableRect($0) }
    }
    public func frames(display: String, slot: Int) -> [UInt32: CGRect]? {
        byDisplay[display]?[slot]?.mapValues { $0.cgRect }
    }
}
