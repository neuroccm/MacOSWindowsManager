import CoreGraphics
import Foundation

public enum LayoutMode: String, CaseIterable, Codable, Identifiable {
    case stable, bsp, masterStack, columns, grid
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .stable: return "Stable — halves & quarters"
        case .bsp: return "BSP (nested splits)"
        case .masterStack: return "Master + Stack"
        case .columns: return "Columns"
        case .grid: return "Grid"
        }
    }
}

public enum SplitOrientation: String, Codable, Equatable {
    case horizontal // children side by side
    case vertical   // children stacked
}

/// Binary split tree: the fractal core. Each display owns one tree.
/// Leaf = one window (by CGWindowID). Split = seam with a ratio.
public indirect enum LayoutNode: Equatable {
    case leaf(id: UInt32)
    case tabs(ids: [UInt32], active: Int)
    case split(orientation: SplitOrientation, ratio: Double, first: LayoutNode, second: LayoutNode)

    public var leafIDs: [UInt32] {
        switch self {
        case .leaf(let id): return [id]
        case .tabs(let ids, _): return ids
        case .split(_, _, let a, let b): return a.leafIDs + b.leafIDs
        }
    }

    public var activeID: UInt32? {
        switch self {
        case .leaf(let id): return id
        case .tabs(let ids, let a): return ids.indices.contains(a) ? ids[a] : ids.first
        case .split(_, _, let a, _): return a.activeID
        }
    }

    /// Readability clamp for every seam: neither side may shrink below 20%
    /// (a 10% sliver is unusable and apps clamp it back, causing overlap churn).
    public static func clampedRatio(_ r: Double) -> Double { min(max(r, 0.2), 0.8) }

    /// Insert by splitting the target leaf (or the first leaf). Split
    /// orientation alternates with tree depth so repeated inserts grow a
    /// grid-like tree instead of an ever-narrower horizontal comb.
    public func inserting(_ newID: UInt32, targetID: UInt32? = nil) -> LayoutNode {
        inserting(newID, targetID: targetID, depth: 0)
    }

    private func inserting(_ newID: UInt32, targetID: UInt32?, depth: Int) -> LayoutNode {
        if leafIDs.contains(newID) { return self }
        let orientation: SplitOrientation = depth.isMultiple(of: 2) ? .horizontal : .vertical
        switch self {
        case .leaf(let id):
            let target = targetID ?? id
            if id == target {
                return .split(orientation: orientation, ratio: 0.5, first: self, second: .leaf(id: newID))
            }
            return self
        case .tabs:
            // Inserting beside a tab group splits the whole group tile.
            return .split(orientation: orientation, ratio: 0.5, first: self, second: .leaf(id: newID))
        case .split(let o, let r, let a, let b):
            let target = targetID ?? a.leafIDs.first
            if let t = target, a.leafIDs.contains(t) { return .split(orientation: o, ratio: r, first: a.inserting(newID, targetID: t, depth: depth + 1), second: b) }
            if let t = target, b.leafIDs.contains(t) { return .split(orientation: o, ratio: r, first: a, second: b.inserting(newID, targetID: t, depth: depth + 1)) }
            return .split(orientation: o, ratio: r, first: a.inserting(newID, targetID: a.leafIDs.first, depth: depth + 1), second: b)
        }
    }

    /// Drop `newID` onto `targetID`'s center: both share one tile as a tab group.
    public func tabbing(_ newID: UInt32, onto targetID: UInt32) -> LayoutNode {
        if leafIDs.contains(newID) { return self }
        switch self {
        case .leaf(let id):
            return id == targetID ? .tabs(ids: [id, newID], active: 1) : self
        case .tabs(let ids, let a):
            return ids.contains(targetID) ? .tabs(ids: ids + [newID], active: ids.count) : self
        case .split(let o, let r, let a, let b):
            if a.leafIDs.contains(targetID) { return .split(orientation: o, ratio: r, first: a.tabbing(newID, onto: targetID), second: b) }
            if b.leafIDs.contains(targetID) { return .split(orientation: o, ratio: r, first: a, second: b.tabbing(newID, onto: targetID)) }
            return self
        }
    }

    public func settingActiveTab(_ id: UInt32) -> LayoutNode {
        switch self {
        case .tabs(let ids, _):
            if let i = ids.firstIndex(of: id) { return .tabs(ids: ids, active: i) }
            return self
        case .split(let o, let r, let a, let b):
            return .split(orientation: o, ratio: r, first: a.settingActiveTab(id), second: b.settingActiveTab(id))
        case .leaf: return self
        }
    }

    public func cyclingTab(containing id: UInt32, forward: Bool) -> LayoutNode {
        switch self {
        case .tabs(let ids, let a):
            guard ids.contains(id), ids.count > 1 else { return self }
            let n = forward ? (a + 1) % ids.count : (a - 1 + ids.count) % ids.count
            return .tabs(ids: ids, active: n)
        case .split(let o, let r, let a, let b):
            return .split(orientation: o, ratio: r, first: a.cyclingTab(containing: id, forward: forward), second: b.cyclingTab(containing: id, forward: forward))
        case .leaf: return self
        }
    }

    /// Tear a tab out of its group and dock it beside the group.
    public func tearingOff(_ id: UInt32) -> LayoutNode {
        switch self {
        case .tabs(let ids, let a):
            guard ids.contains(id), ids.count > 1 else { return self }
            let rest = ids.filter { $0 != id }
            let restNode: LayoutNode = rest.count == 1 ? .leaf(id: rest[0]) : .tabs(ids: rest, active: min(a, rest.count - 1))
            return .split(orientation: .horizontal, ratio: 0.5, first: restNode, second: .leaf(id: id))
        case .split(let o, let r, let a, let b):
            if a.leafIDs.contains(id), case .tabs = a { return .split(orientation: o, ratio: r, first: a.tearingOff(id), second: b) }
            if b.leafIDs.contains(id), case .tabs = b { return .split(orientation: o, ratio: r, first: a, second: b.tearingOff(id)) }
            return self
        case .leaf: return self
        }
    }

    /// Dock `newID` on an edge of `targetID` (left/right = horizontal split, top/bottom = vertical).
    public func docking(_ newID: UInt32, on targetID: UInt32, zone: DockZone) -> LayoutNode {
        if zone == .center { return tabbing(newID, onto: targetID) }
        if leafIDs.contains(newID) { return self }
        switch self {
        case .leaf, .tabs:
            guard leafIDs.contains(targetID) else { return self }
            let me = self, new = LayoutNode.leaf(id: newID)
            switch zone {
            case .left: return .split(orientation: .horizontal, ratio: 0.5, first: new, second: me)
            case .right: return .split(orientation: .horizontal, ratio: 0.5, first: me, second: new)
            case .top: return .split(orientation: .vertical, ratio: 0.5, first: new, second: me)
            case .bottom: return .split(orientation: .vertical, ratio: 0.5, first: me, second: new)
            case .center: return self
            }
        case .split(let o, let r, let a, let b):
            if a.leafIDs.contains(targetID) { return .split(orientation: o, ratio: r, first: a.docking(newID, on: targetID, zone: zone), second: b) }
            if b.leafIDs.contains(targetID) { return .split(orientation: o, ratio: r, first: a, second: b.docking(newID, on: targetID, zone: zone)) }
            return self
        }
    }

    /// Adjust the nearest split seam that separates the tile containing `id`.
    public func adjustingSeam(containing id: UInt32, delta: Double) -> LayoutNode {
        switch self {
        case .split(let o, let r, let a, let b):
            if a.leafIDs.contains(id), b.leafIDs.count >= 1, a.leafIDs.count == 1 || b.leafIDs.count == 1 {
                return .split(orientation: o, ratio: LayoutNode.clampedRatio(r + delta), first: a, second: b)
            }
            if a.leafIDs.contains(id) { return .split(orientation: o, ratio: r, first: a.adjustingSeam(containing: id, delta: delta), second: b) }
            if b.leafIDs.contains(id) { return .split(orientation: o, ratio: r, first: a, second: b.adjustingSeam(containing: id, delta: delta)) }
            return self
        case .leaf, .tabs: return self
        }
    }

    /// Divider (seam) rectangles for hit-testing seam drags.
    public func seamRects(in rect: CGRect, gap: CGFloat, thickness: CGFloat = 12) -> [CGRect] {
        switch self {
        case .leaf, .tabs: return []
        case .split(let o, let r, let a, let b):
            let clamped = LayoutNode.clampedRatio(r)
            if o == .horizontal {
                let x = rect.minX + rect.width * CGFloat(clamped)
                let seam = CGRect(x: x - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
                let ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(clamped), height: rect.height)
                let rb = CGRect(x: x, y: rect.minY, width: rect.width - rect.width * CGFloat(clamped), height: rect.height)
                return [seam] + a.seamRects(in: ra, gap: gap, thickness: thickness) + b.seamRects(in: rb, gap: gap, thickness: thickness)
            } else {
                let y = rect.minY + rect.height * CGFloat(clamped)
                let seam = CGRect(x: rect.minX, y: y - thickness / 2, width: rect.width, height: thickness)
                let ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * CGFloat(clamped))
                let rb = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height - rect.height * CGFloat(clamped))
                return [seam] + a.seamRects(in: ra, gap: gap, thickness: thickness) + b.seamRects(in: rb, gap: gap, thickness: thickness)
            }
        }
    }

    public func removing(_ id: UInt32) -> LayoutNode? {
        switch self {
        case .leaf(let lid): return lid == id ? nil : self
        case .tabs(let ids, let a):
            guard ids.contains(id) else { return self }
            let rest = ids.filter { $0 != id }
            if rest.isEmpty { return nil }
            if rest.count == 1 { return .leaf(id: rest[0]) }
            return .tabs(ids: rest, active: min(a, rest.count - 1))
        case .split(_, _, let a, let b):
            if a.leafIDs == [id] { return b }
            if b.leafIDs == [id] { return a }
            let na = a.removing(id), nb = b.removing(id)
            switch (na, nb) {
            case (nil, let x?): return x
            case (let x?, nil): return x
            case (let x?, let y?): 
                if case .split(let o, let r, _, _) = self { return .split(orientation: o, ratio: r, first: x, second: y) }
                return x
            case (nil, nil): return nil
            }
        }
    }

    public func frames(in rect: CGRect, gap: CGFloat) -> [UInt32: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect.insetBy(dx: gap / 2, dy: gap / 2)]
        case .tabs(let ids, _):
            // Tab group: every tab maps to the same tile; manager raises only the active one.
            let r = rect.insetBy(dx: gap / 2, dy: gap / 2)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, r) })
        case .split(let o, let r, let a, let b):
            let clamped = LayoutNode.clampedRatio(r)
            let (ra, rb): (CGRect, CGRect)
            if o == .horizontal {
                let w = rect.width * CGFloat(clamped)
                ra = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
                rb = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            } else {
                let h = rect.height * CGFloat(clamped)
                ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
                rb = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            }
            return a.frames(in: ra, gap: gap).merging(b.frames(in: rb, gap: gap)) { $1 }
        }
    }

    /// Genuinely balanced tree: recursively halves the ID list, alternating
    /// split orientation by depth. Every leaf ends up within ~2x the area
    /// of every other leaf — the old linear chain halved widths per window
    /// (6 windows -> some tiles were 1/32 of the display). On a portrait
    /// display the first split stacks vertically instead of carving the
    /// narrow display into side-by-side columns.
    public static func balanced(ids: [UInt32], portrait: Bool = false) -> LayoutNode? {
        buildBalanced(ids[...], depth: 0, portrait: portrait)
    }

    private static func buildBalanced(_ ids: ArraySlice<UInt32>, depth: Int, portrait: Bool) -> LayoutNode? {
        guard let first = ids.first else { return nil }
        if ids.count == 1 { return .leaf(id: first) }
        let mid = ids.startIndex + ids.count / 2
        guard let a = buildBalanced(ids[..<mid], depth: depth + 1, portrait: portrait),
              let b = buildBalanced(ids[mid...], depth: depth + 1, portrait: portrait) else { return .leaf(id: first) }
        let sideBySide = depth.isMultiple(of: 2) != portrait
        return .split(orientation: sideBySide ? .horizontal : .vertical,
                      ratio: 0.5, first: a, second: b)
    }
}

/// Pure frame solver used by the tiling manager (no AX / AppKit dependency).
/// Every mode respects a minimum readable tile size: once tiles would get
/// smaller than that, extra windows share the last tile (tab semantics)
/// instead of subdividing into slivers apps will only clamp back.
public enum LayoutEngine {
    public static let minTileWidth: CGFloat = 280
    public static let minTileHeight: CGFloat = 200

    public static func frames(ids: [UInt32], in rect: CGRect, gap: CGFloat, mode: LayoutMode, masterRatio: Double = 0.6) -> [UInt32: CGRect] {
        guard !ids.isEmpty else { return [:] }
        if ids.count == 1 { return [ids[0]: rect.insetBy(dx: gap / 2, dy: gap / 2)] }
        switch mode {
        case .stable:
            // ID-only fallback (TilingManager uses the app-aware planner);
            // order is taken as given, slots are halves/quarters.
            let inputs = ids.map { StableWindowInput(id: $0, bundleID: "", appName: "", isFocused: false, currentFrame: .zero) }
            return StableLayout.plan(windows: inputs, previousOrder: ids, in: rect, gap: gap).frames
        case .bsp:
            let capacity = max(1, Int(rect.width / minTileWidth) * Int(rect.height / minTileHeight))
            let visible = Array(ids.prefix(capacity))
            guard let tree = LayoutNode.balanced(ids: visible, portrait: DisplayGeometry.isPortrait(rect)) else { return [:] }
            var out = tree.frames(in: rect, gap: gap)
            if let last = visible.last, let hostFrame = out[last] {
                for id in ids.dropFirst(capacity) { out[id] = hostFrame }
            }
            return out
        case .masterStack:
            let ratio = CGFloat(min(max(masterRatio, 0.2), 0.8))
            var out: [UInt32: CGRect] = [:]
            let rest = Array(ids.dropFirst())
            if DisplayGeometry.isPortrait(rect) {
                // Master on top (full width), stack side by side below it.
                let masterH = rect.height * ratio
                let master = CGRect(x: rect.minX, y: rect.maxY - masterH, width: rect.width, height: masterH)
                out[ids[0]] = master.insetBy(dx: gap / 2, dy: gap / 2)
                let stack = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - masterH)
                let cols = max(1, min(rest.count, Int(stack.width / minTileWidth)))
                let eachW = stack.width / CGFloat(cols)
                for (i, id) in rest.enumerated() {
                    let col = min(i, cols - 1) // overflow shares the last column
                    let r = CGRect(x: stack.minX + eachW * CGFloat(col), y: stack.minY, width: eachW, height: stack.height)
                    out[id] = r.insetBy(dx: gap / 2, dy: gap / 2)
                }
                return out
            }
            let masterW = rect.width * ratio
            let master = CGRect(x: rect.minX, y: rect.minY, width: masterW, height: rect.height)
            out[ids[0]] = master.insetBy(dx: gap / 2, dy: gap / 2)
            let stack = CGRect(x: rect.minX + masterW, y: rect.minY, width: rect.width - masterW, height: rect.height)
            let rows = max(1, min(rest.count, Int(stack.height / minTileHeight)))
            let eachH = stack.height / CGFloat(rows)
            for (i, id) in rest.enumerated() {
                let row = min(i, rows - 1) // overflow shares the last row
                let r = CGRect(x: stack.minX, y: stack.minY + eachH * CGFloat(row), width: stack.width, height: eachH)
                out[id] = r.insetBy(dx: gap / 2, dy: gap / 2)
            }
            return out
        case .columns:
            var out: [UInt32: CGRect] = [:]
            if DisplayGeometry.isPortrait(rect) {
                // "Columns" on a portrait display are full-width rows.
                let rows = max(1, min(ids.count, Int(rect.height / minTileHeight)))
                let h = rect.height / CGFloat(rows)
                for (i, id) in ids.enumerated() {
                    let row = min(i, rows - 1) // overflow shares the last row
                    out[id] = CGRect(x: rect.minX, y: rect.minY + h * CGFloat(row), width: rect.width, height: h).insetBy(dx: gap / 2, dy: gap / 2)
                }
                return out
            }
            let cols = max(1, min(ids.count, Int(rect.width / minTileWidth)))
            let w = rect.width / CGFloat(cols)
            for (i, id) in ids.enumerated() {
                let col = min(i, cols - 1) // overflow shares the last column
                out[id] = CGRect(x: rect.minX + w * CGFloat(col), y: rect.minY, width: w, height: rect.height).insetBy(dx: gap / 2, dy: gap / 2)
            }
            return out
        case .grid:
            // Choose columns so cell aspect stays readable on any display
            // shape (target = display aspect, clamped so portrait screens
            // stack full-width cells instead of skinny columns).
            let screenAspect = Double(rect.width / rect.height)
            let target = min(max(screenAspect, 0.75), 2.2)
            let ideal = sqrt(Double(ids.count) * screenAspect / target)
            var cols = gridColumnCount(ideal: ideal, count: ids.count, screenAspect: screenAspect, target: target)
            var rows = Int(ceil(Double(ids.count) / Double(cols)))
            cols = max(1, min(cols, Int(rect.width / minTileWidth)))
            rows = max(1, min(rows, Int(rect.height / minTileHeight)))
            let w = rect.width / CGFloat(cols), h = rect.height / CGFloat(rows)
            let capacity = cols * rows
            var out: [UInt32: CGRect] = [:]
            for (i, id) in ids.enumerated() {
                let cell = min(i, capacity - 1) // overflow shares the last cell
                let c = cell % cols, r = cell / cols
                out[id] = CGRect(x: rect.minX + w * CGFloat(c), y: rect.minY + h * CGFloat(r), width: w, height: h).insetBy(dx: gap / 2, dy: gap / 2)
            }
            return out
        }
    }
}

private func gridColumnCount(ideal: Double, count: Int, screenAspect: Double, target: Double) -> Int {
    let lo = max(1, Int(ideal.rounded(.down)))
    let hi = max(lo, min(count, Int(ideal.rounded(.up))))
    guard hi != lo else { return lo }
    func score(_ cols: Int) -> Double {
        let cellAspect = screenAspect * Double(count) / Double(cols * cols)
        return abs(log(cellAspect / target))
    }
    if abs(score(lo) - score(hi)) < 0.001 { return screenAspect >= 1 ? hi : lo }
    return score(lo) < score(hi) ? lo : hi
}

public enum DockZone: String, Equatable { case left, right, top, bottom, center }

/// Which physical display owns a window/point, for any number of
/// displays in any arrangement. Largest overlap wins; a frame in a
/// dead zone (mixed-height neighbours) goes to the nearest display —
/// never to whichever display holds keyboard focus.
public enum DisplayGeometry {
    public static func isPortrait(_ rect: CGRect) -> Bool { rect.height > rect.width }

    public static func screenIndex(forCocoaRect rect: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var bestIndex = 0, bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() {
            let inter = rect.intersection(s)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; bestIndex = i }
        }
        if bestArea > 0 { return bestIndex }
        return screenIndex(forCocoaPoint: CGPoint(x: rect.midX, y: rect.midY), screens: screens)
    }

    public static func screenIndex(forCocoaPoint p: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let i = screens.firstIndex(where: { $0.contains(p) }) { return i }
        return screens.enumerated().min { distance(p, to: $0.element) < distance(p, to: $1.element) }?.offset
    }

    static func distance(_ p: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return hypot(dx, dy)
    }
}

/// Pure dock hit-testing shared by drag-to-dock and tests.
public enum DockGeometry {
    /// A real macOS window drag starts from the title bar / toolbar band.
    /// Requiring the grab to start there means text selections, content
    /// drags, and Mission Control thumbnail drags are never mistaken for
    /// "drag this window somewhere to dock it". Cocoa coords: top = maxY.
    public static func isTitleBarDrag(point: CGPoint, in rect: CGRect, bandHeight: CGFloat = 48) -> Bool {
        rect.contains(point) && point.y >= rect.maxY - bandHeight
    }

    /// Zone inside a window/screen rect: center 50% tabs, edges dock.
    public static func zone(at point: CGPoint, in rect: CGRect, centerFraction: CGFloat = 0.5) -> DockZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let cx = rect.minX + rect.width * (1 - centerFraction) / 2
        let cy = rect.minY + rect.height * (1 - centerFraction) / 2
        let center = CGRect(x: cx, y: cy, width: rect.width * centerFraction, height: rect.height * centerFraction)
        if center.contains(point) { return .center }
        let dxl = point.x - rect.minX, dxr = rect.maxX - point.x
        let dyt = rect.maxY - point.y, dyb = point.y - rect.minY // cocoa: maxY is top
        let m = min(dxl, dxr, dyt, dyb)
        if m == dxl { return .left }; if m == dxr { return .right }
        if m == dyt { return .top }; return .bottom
    }
}

/// Cocoa (bottom-left) <-> AX (top-left of primary display) conversion.
public enum CoordinateConverter {
    public static func axFrame(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    public static func cocoaFrame(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    public static func cocoaPoint(fromAX point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
