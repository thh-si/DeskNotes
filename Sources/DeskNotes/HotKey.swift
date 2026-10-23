import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through the Carbon hot-key API. Unlike event taps or key monitors,
/// this needs no Accessibility / Input Monitoring permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x444B4E54), id: id)  // 'DKNT'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("DeskNotes: could not register hot key (status \(status)); another app may already use it")
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
