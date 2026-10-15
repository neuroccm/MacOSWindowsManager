import CoreGraphics
import Foundation

/// What kind of app a window belongs to. Windows in the same (non-`.other`)
/// category — or from the same app — are "similar" and pair side by side.
public enum AppCategory: String, Equatable {
    case browser, messaging, mail, code, terminal, documents, media, meetings, other
}

public enum AppClassifier {
    private static let byBundleID: [String: AppCategory] = [
        // Browsers
        "com.apple.safari": .browser, "com.google.chrome": .browser,
        "org.mozilla.firefox": .browser, "company.thebrowser.browser": .browser,
        "com.brave.browser": .browser, "com.microsoft.edgemac": .browser,
        "com.operasoftware.opera": .browser, "org.chromium.chromium": .browser,
        "com.vivaldi.vivaldi": .browser, "org.torproject.torbrowser": .browser,
        // Messaging & chat
        "com.apple.mobilesms": .messaging, "com.tinyspeck.slackmacgap": .messaging,
        "com.hnc.discord": .messaging, "net.whatsapp.whatsapp": .messaging,
        "org.telegram.desktop": .messaging, "ru.keepcoder.telegram": .messaging,
        "org.whispersystems.signal-desktop": .messaging, "com.microsoft.teams": .messaging,
        "com.microsoft.teams2": .messaging, "com.facebook.archon": .messaging, // Messenger
        // Mail
        "com.apple.mail": .mail, "com.microsoft.outlook": .mail,
        "com.readdle.smartemail-macos": .mail, "org.mozilla.thunderbird": .mail,
        "com.postbox-inc.postbox": .mail, "fr.airmailforiphone.airmail3": .mail,
        // Code / development
        "com.microsoft.vscode": .code, "com.apple.dt.xcode": .code,
        "com.sublimetext.4": .code, "com.sublimetext.3": .code,
        "dev.zed.zed": .code, "com.todesktop.230313mzl4w4u92": .code, // Cursor
        "com.github.atom": .code, "com.panic.nova": .code,
        "org.gnu.emacs": .code, "com.apple.textedit": .documents,
        // Terminals
        "com.apple.terminal": .terminal, "com.googlecode.iterm2": .terminal,
        "dev.warp.warp-stable": .terminal, "com.mitchellh.ghostty": .terminal,
        "net.kovidgoyal.kitty": .terminal, "org.alacritty": .terminal,
        // Documents, notes & reading
        "com.apple.preview": .documents, "com.microsoft.word": .documents,
        "com.microsoft.powerpoint": .documents, "com.microsoft.excel": .documents,
        "com.apple.iwork.pages": .documents, "com.apple.iwork.keynote": .documents,
        "com.apple.iwork.numbers": .documents, "org.libreoffice.script": .documents,
        "com.adobe.reader": .documents, "com.adobe.acrobat.pro": .documents,
        "notion.id": .documents, "md.obsidian": .documents,
        "com.evernote.evernote": .documents, "com.apple.notes": .documents,
        "com.omnigroup.omnioutliner5": .documents, "org.zotero.zotero": .documents,
        // Media
        "com.apple.music": .media, "com.spotify.client": .media,
        "com.apple.tv": .media, "com.apple.photos": .media,
        "com.apple.quicktimeplayerx": .media, "org.videolan.vlc": .media,
        "com.apple.podcasts": .media, "com.apple.imovieapp": .media,
        // Meetings
        "us.zoom.xos": .meetings, "com.cisco.webexmeetingsapp": .meetings,
        "com.logmein.gotomeeting": .meetings,
    ]

    private static let nameKeywords: [(String, AppCategory)] = [
        ("chrome", .browser), ("firefox", .browser), ("safari", .browser),
        ("brave", .browser), ("opera", .browser), ("vivaldi", .browser), ("browser", .browser),
        ("slack", .messaging), ("discord", .messaging), ("telegram", .messaging),
        ("whatsapp", .messaging), ("signal", .messaging), ("messages", .messaging),
        ("outlook", .mail), ("thunderbird", .mail), ("spark", .mail), ("airmail", .mail),
        ("xcode", .code), ("visual studio code", .code), ("sublime", .code), ("zed", .code),
        ("terminal", .terminal), ("iterm", .terminal), ("ghostty", .terminal), ("warp", .terminal),
        ("preview", .documents), ("pages", .documents), ("keynote", .documents),
        ("notion", .documents), ("obsidian", .documents), ("word", .documents),
        ("spotify", .media), ("vlc", .media), ("music", .media),
        ("zoom", .meetings), ("webex", .meetings),
    ]

    public static func category(bundleID: String, appName: String) -> AppCategory {
        let bid = bundleID.lowercased()
        if let c = byBundleID[bid] { return c }
        if bid.contains(".jetbrains.") || bid.hasPrefix("com.jetbrains") { return .code }
        let name = appName.lowercased()
        for (keyword, category) in nameKeywords where name.contains(keyword) { return category }
        return .other
    }

    public static func areSimilar(bundleA: String, nameA: String, bundleB: String, nameB: String) -> Bool {
        if !bundleA.isEmpty, bundleA.caseInsensitiveCompare(bundleB) == .orderedSame { return true }
        let a = category(bundleID: bundleA, appName: nameA)
        let b = category(bundleID: bundleB, appName: nameB)
        return a != .other && a == b
    }
}

/// One window as seen by the stable planner (pure value; no AX dependency).
public struct StableWindowInput: Equatable {
    public var id: UInt32
    public var bundleID: String
    public var appName: String
    public var isFocused: Bool
    public var currentFrame: CGRect // Cocoa coords; reserved for future spatial seeding
    public init(id: UInt32, bundleID: String, appName: String, isFocused: Bool, currentFrame: CGRect) {
        self.id = id; self.bundleID = bundleID; self.appName = appName
        self.isFocused = isFocused; self.currentFrame = currentFrame
    }
}

/// Result of one stable planning pass for a single display.
public struct StablePlan: Equatable {
    /// Reading order: primary first, then visible slots, then overflow.
    /// Feed this back as `previousOrder` next time — that is what keeps
    /// windows from shuffling when nothing meaningful changed.
    public var orderedIDs: [UInt32]
    public var visibleCount: Int
    public var frames: [UInt32: CGRect] // Cocoa coords; overflow shares its host's frame
    /// Overflow window ID -> visible host window ID whose tile it tabs behind.
    public var tabbedBehind: [UInt32: UInt32]
}

/// The automatic arranger. Per display it only ever produces:
/// 1 window = full, 2 = halves, 3 = one half + two quarters,
/// 4 = quarters. A 5th+ window never subdivides further — it tabs
/// behind a similar window's tile (or the last tile), and is promoted
/// into a real slot, in order, when a visible window closes.
///
/// Stability rules (the anti-churn contract):
/// - Survivors keep their slot and relative order. Focus changes alone
///   never move anything; only window-set changes re-plan.
/// - A newcomer takes the newly created / last slot. At most ONE swap
///   is allowed: a newcomer similar to the primary may swap into the
///   earliest dissimilar secondary slot so pairs sit side by side.
///   The primary (slot 0) itself never moves once placed.
/// - When a window leaves, later windows shift up one slot in reading
///   order (each into an equal-or-larger tile); slot 0 is untouched.
public enum StableLayout {
    /// Smallest tile that is still comfortable to read.
    public static let minQuarterWidth: CGFloat = 440
    public static let minQuarterHeight: CGFloat = 300

    /// How many real tiles this display gets: 4, 2, or 1 — never more,
    /// and never 3 unless a quarter is readable (3 needs two quarters).
    public static func maxVisible(in rect: CGRect) -> Int {
        if rect.width / 2 >= minQuarterWidth, rect.height / 2 >= minQuarterHeight { return 4 }
        if rect.width >= rect.height {
            if rect.width / 2 >= 360, rect.height >= 280 { return 2 }
        } else {
            if rect.height / 2 >= 280, rect.width >= 360 { return 2 }
        }
        return 1
    }

    /// Slot rectangles in reading order (Cocoa: origin bottom-left, so the
    /// "top" row has the larger minY).
    public static func slotRects(count: Int, in rect: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let hw = rect.width / 2, hh = rect.height / 2
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x, y: rect.minY + y, width: w, height: h)
        }
        switch count {
        case 1:
            return [rect]
        case 2:
            return rect.width >= rect.height
                ? [r(0, 0, hw, rect.height), r(hw, 0, hw, rect.height)]          // left | right
                : [r(0, hh, rect.width, hh), r(0, 0, rect.width, hh)]            // top / bottom
        case 3:
            return rect.width >= rect.height
                ? [r(0, 0, hw, rect.height), r(hw, hh, hw, hh), r(hw, 0, hw, hh)]  // half | TR, BR
                : [r(0, hh, rect.width, hh), r(0, 0, hw, hh), r(hw, 0, hw, hh)]    // top half | BL, BR
        default: // 4 quarters: TL, TR, BL, BR
            return [r(0, hh, hw, hh), r(hw, hh, hw, hh), r(0, 0, hw, hh), r(hw, 0, hw, hh)]
        }
    }

    public static func plan(windows: [StableWindowInput], previousOrder: [UInt32],
                            in rect: CGRect, gap: CGFloat) -> StablePlan {
        guard !windows.isEmpty else {
            return StablePlan(orderedIDs: [], visibleCount: 0, frames: [:], tabbedBehind: [:])
        }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let survivors = previousOrder.filter { byID[$0] != nil }
        let newcomers = windows.map(\.id).filter { !previousOrder.contains($0) }

        var order: [UInt32]
        if survivors.isEmpty {
            // Fresh display: focused window is primary, its similars pair
            // beside it, everything else follows in enumeration order.
            let primary = (windows.first { $0.isFocused } ?? windows[0]).id
            let p = byID[primary]!
            let similars = windows.filter { $0.id != primary && AppClassifier.areSimilar(
                bundleA: p.bundleID, nameA: p.appName, bundleB: $0.bundleID, nameB: $0.appName) }.map(\.id)
            let rest = windows.filter { $0.id != primary && !similars.contains($0.id) }.map(\.id)
            order = [primary] + similars + rest
        } else {
            order = survivors + newcomers
            applyPairingSwap(order: &order, newcomers: newcomers, byID: byID,
                             visibleLimit: maxVisible(in: rect))
        }

        let visible = min(order.count, maxVisible(in: rect))
        let slots = slotRects(count: visible, in: rect)
        var frames: [UInt32: CGRect] = [:]
        for (i, id) in order.prefix(visible).enumerated() {
            frames[id] = slots[i].insetBy(dx: gap / 2, dy: gap / 2)
        }
        var tabbed: [UInt32: UInt32] = [:]
        for id in order.dropFirst(visible) {
            guard let w = byID[id] else { continue }
            let visibleIDs = Array(order.prefix(visible))
            // Prefer tabbing behind the same app, then a similar app, else the last tile.
            let host = visibleIDs.first { byID[$0]?.bundleID.caseInsensitiveCompare(w.bundleID) == .orderedSame }
                ?? visibleIDs.first { h in byID[h].map { AppClassifier.areSimilar(
                    bundleA: $0.bundleID, nameA: $0.appName, bundleB: w.bundleID, nameB: w.appName) } ?? false }
                ?? visibleIDs.last!
            tabbed[id] = host
            frames[id] = frames[host]
        }
        return StablePlan(orderedIDs: order, visibleCount: visible, frames: frames, tabbedBehind: tabbed)
    }

    /// The single allowed rearrangement: a newcomer similar to the primary
    /// swaps into the earliest visible secondary slot held by a dissimilar
    /// window, so the pair sits side by side. Slot 0 and every other
    /// survivor keep their relative order.
    private static func applyPairingSwap(order: inout [UInt32], newcomers: [UInt32],
                                         byID: [UInt32: StableWindowInput], visibleLimit: Int) {
        guard order.count > 2, let primary = byID[order[0]] else { return }
        for newID in newcomers {
            guard let newWin = byID[newID], let newIndex = order.firstIndex(of: newID),
                  AppClassifier.areSimilar(bundleA: primary.bundleID, nameA: primary.appName,
                                           bundleB: newWin.bundleID, nameB: newWin.appName) else { continue }
            // Earliest visible secondary slot whose occupant is not similar to the primary.
            let limit = min(order.count, visibleLimit)
            guard let slot = (1..<limit).first(where: { i in
                guard let occ = byID[order[i]] else { return false }
                return !AppClassifier.areSimilar(bundleA: primary.bundleID, nameA: primary.appName,
                                                 bundleB: occ.bundleID, nameB: occ.appName)
            }), slot < newIndex else { continue }
            order.swapAt(slot, newIndex)
            return // at most one swap per planning pass
        }
    }
}
