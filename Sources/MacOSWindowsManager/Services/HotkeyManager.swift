import Carbon
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey (no extra dependency, works without Input Monitoring).
@MainActor
public final class HotkeyManager {
    public enum Action: String, CaseIterable {
        case tileAll, floatAll, maximize, focusNext, focusPrev, nextDisplay
        case layoutStable, layoutBSP, layoutMaster, layoutColumns, layoutGrid
        case saveView1, restoreView1
        case zoomIn, zoomOut, back, forward, tabNext, tearOff, seamGrow, seamShrink
        case restoreView2, restoreView3
    }

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    public var onAction: ((Action) -> Void)?

    // Ctrl+Opt combos. Key codes: Space=49, Return=36, T=17, F=3, M=46, Tab=48, D=2, 1=18, B=11, C=8, G=5
    private let specs: [(Action, UInt32, UInt32)] = [
        (.tileAll, UInt32(kVK_Space), UInt32(controlKey | optionKey)),
        (.floatAll, UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey)),
        (.maximize, UInt32(kVK_Return), UInt32(controlKey | optionKey)),
        (.focusNext, UInt32(kVK_Tab), UInt32(controlKey | optionKey)),
        (.nextDisplay, UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey)),
        (.layoutStable, UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey)),
        (.layoutBSP, UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey)),
        (.layoutMaster, UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey)),
        (.layoutColumns, UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey)),
        (.layoutGrid, UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey)),
        (.zoomIn, UInt32(kVK_DownArrow), UInt32(controlKey | optionKey)),
        (.zoomOut, UInt32(kVK_UpArrow), UInt32(controlKey | optionKey)),
        (.back, UInt32(kVK_ANSI_LeftBracket), UInt32(controlKey | optionKey)),
        (.forward, UInt32(kVK_ANSI_RightBracket), UInt32(controlKey | optionKey)),
        (.tabNext, UInt32(kVK_ANSI_Y), UInt32(controlKey | optionKey)),
        (.tearOff, UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey)),
        (.seamGrow, UInt32(kVK_ANSI_Equal), UInt32(controlKey | optionKey)),
        (.seamShrink, UInt32(kVK_ANSI_Minus), UInt32(controlKey | optionKey)),
        (.saveView1, UInt32(kVK_ANSI_1), UInt32(controlKey | optionKey | shiftKey)),
        (.restoreView1, UInt32(kVK_ANSI_1), UInt32(controlKey | optionKey)),
        (.restoreView2, UInt32(kVK_ANSI_2), UInt32(controlKey | optionKey)),
        (.restoreView3, UInt32(kVK_ANSI_3), UInt32(controlKey | optionKey)),
    ]

    public init() {}

    public func registerAll() {
        unregisterAll()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let action = mgr.action(forSignatureID: hkID.id) {
                Task { @MainActor in mgr.onAction?(action) }
            }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        for (index, (action, keyCode, mods)) in specs.enumerated() {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x4D57_4D47), id: UInt32(index + 1))
            _ = action // signature id maps by index; see action(forSignatureID:)
            RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    private func action(forSignatureID id: UInt32) -> Action? {
        let idx = Int(id) - 1
        guard specs.indices.contains(idx) else { return nil }
        return specs[idx].0
    }

    public func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }
    deinit { for ref in refs { if let ref { UnregisterEventHotKey(ref) } } }
}
