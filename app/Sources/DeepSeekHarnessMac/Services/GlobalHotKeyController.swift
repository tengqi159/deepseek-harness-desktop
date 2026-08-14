import Carbon
import Foundation

@MainActor
final class GlobalHotKeyController {
    private static let defaultSignature: OSType = 0x44534841 // "DSHA"

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: @MainActor () -> Void
    private let signature: OSType
    private let identifier: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var lastInvocation: ContinuousClock.Instant?

    init(action: @escaping @MainActor () -> Void) {
        self.signature = Self.defaultSignature
        self.identifier = 1
        self.keyCode = UInt32(kVK_ANSI_2)
        self.modifiers = UInt32(cmdKey | shiftKey | optionKey)
        self.action = action
    }

#if DEBUG
    init(
        qaSignature: OSType,
        qaIdentifier: UInt32,
        qaKeyCode: UInt32,
        qaModifiers: UInt32,
        action: @escaping @MainActor () -> Void
    ) {
        self.signature = qaSignature
        self.identifier = qaIdentifier
        self.keyCode = qaKeyCode
        self.modifiers = qaModifiers
        self.action = action
    }
#endif

    func register() throws {
        guard hotKey == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw HotKeyError.registrationFailed(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: signature, id: self.identifier)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            self.eventHandler = nil
            throw HotKeyError.registrationFailed(registrationStatus)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func invoke() {
        let now = ContinuousClock.now
        if let lastInvocation,
           now - lastInvocation < .milliseconds(250) {
            return
        }
        lastInvocation = now
        action()
    }

    private static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == controller.signature,
              identifier.id == controller.identifier else {
            return OSStatus(eventNotHandledErr)
        }
        Task { @MainActor in controller.invoke() }
        return noErr
    }

    private enum HotKeyError: LocalizedError {
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "无法注册 Appshot 快捷键（\(status)）。"
            }
        }
    }
}
