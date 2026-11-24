import Carbon
import Foundation

/// System-wide hotkeys through Carbon `RegisterEventHotKey` — works from any app, no Accessibility permission needed.
/// Two independent groups: the account slots (⌘⌥1…⌘⌥9) and the quick switcher shortcut.
@MainActor
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    private static let signature: OSType = 0x43444B31 // 'CDK1'
    private static let switcherID: UInt32 = 100

    private var slotRefs: [EventHotKeyRef?] = []
    private var switcherRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onSlot: ((Int) -> Void)?
    private var onSwitcher: (() -> Void)?

    private static let numberKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
    ]

    private init() {}

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == GlobalHotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let id = hkID.id
            Task { @MainActor in
                if id == GlobalHotkeyManager.switcherID {
                    GlobalHotkeyManager.shared.onSwitcher?()
                } else {
                    GlobalHotkeyManager.shared.onSlot?(Int(id))
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)
    }

    /// Registers ⌘⌥1…⌘⌥count and returns the slot indices that actually registered.
    /// A slot fails when another app already owns that shortcut; callers must only advertise returned slots.
    @discardableResult
    public func register(count: Int, handler: @escaping (Int) -> Void) -> Set<Int> {
        unregisterSlots()
        onSlot = handler
        let clamped = min(max(0, count), Self.numberKeyCodes.count)
        guard clamped > 0 else { return [] }
        installHandlerIfNeeded()
        var registered = Set<Int>()
        let modifiers = UInt32(cmdKey | optionKey)
        for index in 0..<clamped {
            var ref: EventHotKeyRef?
            let rc = RegisterEventHotKey(Self.numberKeyCodes[index], modifiers,
                                         EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                         GetApplicationEventTarget(), 0, &ref)
            if rc == noErr {
                slotRefs.append(ref)
                registered.insert(index)
            }
        }
        return registered
    }

    /// Registers the quick switcher shortcut. Returns false if another app already owns it.
    @discardableResult
    public func registerSwitcher(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregisterSwitcher()
        onSwitcher = handler
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let rc = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: Self.switcherID),
                                     GetApplicationEventTarget(), 0, &ref)
        guard rc == noErr else { return false }
        switcherRef = ref
        return true
    }

    public func unregisterSlots() {
        for ref in slotRefs { if let ref { UnregisterEventHotKey(ref) } }
        slotRefs.removeAll()
    }

    public func unregisterSwitcher() {
        if let ref = switcherRef { UnregisterEventHotKey(ref) }
        switcherRef = nil
    }

    public func unregisterAll() {
        unregisterSlots()
        unregisterSwitcher()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
