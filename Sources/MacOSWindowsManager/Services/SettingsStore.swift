import Foundation
import SwiftUI

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var isTilingEnabled: Bool { didSet { defaults.set(isTilingEnabled, forKey: Keys.tiling) } }
    @Published public var layoutMode: LayoutMode { didSet { defaults.set(layoutMode.rawValue, forKey: Keys.mode) } }
    @Published public var gap: Double { didSet { defaults.set(gap, forKey: Keys.gap) } }
    @Published public var masterRatio: Double { didSet { defaults.set(masterRatio, forKey: Keys.master) } }
    @Published public var excludedBundleIDs: Set<String> { didSet { defaults.set(Array(excludedBundleIDs), forKey: Keys.excluded) } }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let tiling = "tilingEnabled", mode = "layoutMode", gap = "gap", master = "masterRatio", excluded = "excludedBundleIDs"
        static let migratedToStable = "layoutModeMigratedToStable.v1"
    }

    public init() {
        isTilingEnabled = defaults.object(forKey: Keys.tiling) as? Bool ?? false
        layoutMode = LayoutMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .stable
        gap = defaults.object(forKey: Keys.gap) as? Double ?? 8
        masterRatio = defaults.object(forKey: Keys.master) as? Double ?? 0.6
        excludedBundleIDs = Set(defaults.stringArray(forKey: Keys.excluded) ?? [])
        // One-time migration: v1.1 makes Stable (halves & quarters) the
        // automatic default instead of unbounded BSP nesting.
        if !defaults.bool(forKey: Keys.migratedToStable) {
            defaults.set(true, forKey: Keys.migratedToStable)
            if layoutMode == .bsp {
                layoutMode = .stable
                defaults.set(layoutMode.rawValue, forKey: Keys.mode) // didSet doesn't fire in init
            }
        }
    }

    public func toggleExcluded(bundleID: String) {
        if excludedBundleIDs.contains(bundleID) { excludedBundleIDs.remove(bundleID) } else { excludedBundleIDs.insert(bundleID) }
    }
}
