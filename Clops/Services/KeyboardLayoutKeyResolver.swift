import Carbon.HIToolbox
import Foundation

enum KeyboardLayoutKeyResolver {
    private static let commandModifierState = UInt32((cmdKey >> 8) & 0xFF)

    /// Resolves a semantic shortcut character against the active keyboard layout.
    /// The Command modifier matters for layouts such as Dvorak-QWERTY ⌘.
    static func virtualKeyCode(for character: String) -> UInt16? {
        guard let copiedInputSource = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        let inputSource = copiedInputSource.takeRetainedValue()
        guard
            let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        return firstVirtualKeyCode(producing: character) { keyCode in
            translatedString(for: keyCode, layout: layout)
        }
    }

    static func firstVirtualKeyCode(
        producing character: String,
        keyCodes: Range<UInt16> = UInt16(0)..<UInt16(128),
        translate: (UInt16) -> String?
    ) -> UInt16? {
        keyCodes.first { translate($0) == character }
    }

    private static func translatedString(
        for keyCode: UInt16,
        layout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = characters.withUnsafeMutableBufferPointer { buffer in
            UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                commandModifierState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                buffer.count,
                &actualLength,
                buffer.baseAddress!
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        return characters.withUnsafeBufferPointer { buffer in
            String(utf16CodeUnits: buffer.baseAddress!, count: actualLength)
        }
    }
}
