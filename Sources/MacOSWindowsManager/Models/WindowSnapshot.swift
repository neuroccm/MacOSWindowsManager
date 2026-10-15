import AppKit
import CoreGraphics
import Foundation

/// Value snapshot of a managed window (AX element itself lives in AXWindowService).
public struct WindowSnapshot: Identifiable, Equatable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let bundleID: String
    public let title: String
    public var axFrame: CGRect // top-left origin
    public var id: CGWindowID { windowID }
    public var centerAX: CGPoint { CGPoint(x: axFrame.midX, y: axFrame.midY) }
}

/// Saved arrangement (per display) for views 1...9 and restore-on-launch.
public struct SavedView: Codable, Equatable {
    public var slot: Int
    public var framesByWindowID: [String: CodableRect]
    public init(slot: Int, framesByWindowID: [String: CodableRect]) {
        self.slot = slot; self.framesByWindowID = framesByWindowID
    }
}

public struct CodableRect: Codable, Equatable {
    public var x, y, width, height: Double
    public init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); width = Double(r.width); height = Double(r.height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
