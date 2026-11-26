// Глобальные горячие клавиши наборов (⌃⌥1 … ⌃⌥9) через Carbon RegisterEventHotKey: работают, даже когда панель закрыта,
// и не требуют разрешений macOS.
import Carbon
import Foundation

final class Hotkeys {
    nonisolated(unsafe) static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Коды клавиш 1…9 в верхнем ряду.
    static let digitCodes: [UInt32] = [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
                                       UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)]

    /// ⌃⌥ + цифра (index + 1) для каждого действия по порядку; старые сочетания снимаются.
    func setDigits(_ list: [() -> Void]) {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        actions = [:]
        install()
        for (i, action) in list.prefix(Hotkeys.digitCodes.count).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C41_524B), id: UInt32(i + 1))   // 'LARK'
            if RegisterEventHotKey(Hotkeys.digitCodes[i], UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = action
            }
        }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let n = id.id
            DispatchQueue.main.async { Hotkeys.shared.fire(n) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
