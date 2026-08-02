import AppKit
import Carbon

final class GlobalShortcutManager {
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            manager.actions[id.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        clear()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(bindings: [ShortcutAction: ShortcutBinding], handler: @escaping (ShortcutAction) -> Void) {
        clear()
        var identifier: UInt32 = 1
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E4150), id: identifier)
            let status = RegisterEventHotKey(binding.keyCode, carbonModifiers(from: binding.modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
                actions[identifier] = { handler(action) }
                identifier += 1
            }
        }
    }

    private func clear() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()
    }

    private func carbonModifiers(from raw: UInt32) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(raw))
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
