import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
final class GlobalHotKey: ObservableObject {
    static let primaryShortcutLabel = "⌃⌘V"
    static let fallbackShortcutLabel = "⌃⌥⌘V"

    @Published private(set) var isRegistered = false
    @Published private(set) var activeShortcutLabel: String?
    @Published private(set) var registrationError: String?

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var registrationRequested = false
    private var activeVirtualKeyCode: UInt16?
    private var observesInputSourceChanges = false
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        if let notificationCenter = CFNotificationCenterGetDistributedCenter() {
            CFNotificationCenterAddObserver(
                notificationCenter,
                Unmanaged.passUnretained(self).toOpaque(),
                Self.inputSourceChangedCallback,
                kTISNotifySelectedKeyboardInputSourceChanged,
                nil,
                .deliverImmediately
            )
            observesInputSourceChanges = true
        }
    }

    deinit {
        guard
            observesInputSourceChanges,
            let notificationCenter = CFNotificationCenterGetDistributedCenter()
        else { return }
        CFNotificationCenterRemoveObserver(
            notificationCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged),
            nil
        )
    }

    var isUsingFallback: Bool {
        activeShortcutLabel == Self.fallbackShortcutLabel
    }

    func register() {
        registrationRequested = true
        guard let virtualKeyCode = KeyboardLayoutKeyResolver.virtualKeyCode(for: "v") else {
            tearDownRegistration()
            registrationError = "Couldn’t resolve V in the current keyboard layout."
            return
        }
        register(virtualKeyCode: virtualKeyCode)
    }

    func unregister() {
        registrationRequested = false
        tearDownRegistration()
    }

    private func register(virtualKeyCode: UInt16) {
        tearDownRegistration()
        registrationError = nil

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.handler() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandlerReference
        )
        guard handlerStatus == noErr else {
            registrationError = "Couldn’t install shortcut handler (\(handlerStatus))."
            return
        }

        let primaryStatus = registerHotKey(
            virtualKeyCode: virtualKeyCode,
            modifiers: UInt32(controlKey | cmdKey)
        )
        if primaryStatus == noErr {
            finishRegistration(label: Self.primaryShortcutLabel, virtualKeyCode: virtualKeyCode)
            return
        }

        if primaryStatus == eventHotKeyExistsErr {
            hotKeyReference = nil
            let fallbackStatus = registerHotKey(
                virtualKeyCode: virtualKeyCode,
                modifiers: UInt32(controlKey | optionKey | cmdKey)
            )
            if fallbackStatus == noErr {
                finishRegistration(label: Self.fallbackShortcutLabel, virtualKeyCode: virtualKeyCode)
                return
            }

            registrationError = fallbackStatus == eventHotKeyExistsErr
                ? "Both \(Self.primaryShortcutLabel) and \(Self.fallbackShortcutLabel) are used by other apps."
                : "Couldn’t register fallback \(Self.fallbackShortcutLabel) (\(fallbackStatus))."
        } else {
            registrationError = "Couldn’t register \(Self.primaryShortcutLabel) (\(primaryStatus))."
        }
        removeEventHandler()
    }

    private func tearDownRegistration() {
        isRegistered = false
        activeShortcutLabel = nil
        activeVirtualKeyCode = nil
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        removeEventHandler()
    }

    private func registerHotKey(virtualKeyCode: UInt16, modifiers: UInt32) -> OSStatus {
        let identifier = EventHotKeyID(signature: Self.fourCharacterCode("CLPS"), id: 1)
        return RegisterEventHotKey(
            UInt32(virtualKeyCode),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    private func finishRegistration(label: String, virtualKeyCode: UInt16) {
        activeShortcutLabel = label
        activeVirtualKeyCode = virtualKeyCode
        isRegistered = true
        registrationError = nil
    }

    private func inputSourceDidChange() {
        guard registrationRequested else { return }
        guard let virtualKeyCode = KeyboardLayoutKeyResolver.virtualKeyCode(for: "v") else {
            tearDownRegistration()
            registrationError = "Couldn’t resolve V in the current keyboard layout."
            return
        }
        guard virtualKeyCode != activeVirtualKeyCode || !isRegistered else { return }
        register(virtualKeyCode: virtualKeyCode)
    }

    private func removeEventHandler() {
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    private static func fourCharacterCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }

    private static let inputSourceChangedCallback: CFNotificationCallback = {
        _, observer, _, _, _ in
        guard let observer else { return }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(observer).takeUnretainedValue()
        Task { @MainActor in
            hotKey.inputSourceDidChange()
        }
    }
}
