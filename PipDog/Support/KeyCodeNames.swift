import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 键码、修饰键与显示文字（⌃⌥P）之间的换算。
@MainActor
enum KeyCodeNames {
    // MARK: 修饰键

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func flags(fromCarbon modifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// 按苹果惯用顺序 ⌃⌥⇧⌘ 输出修饰键符号。
    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        ClickModifier.allCases.filter { flags.contains($0.flag) }.map(\.symbol).joined()
    }

    static func display(_ combo: KeyCombo) -> String {
        symbols(for: flags(fromCarbon: combo.modifiers)) + keyName(combo.keyCode)
    }

    // MARK: 按键

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = specialNames[Int(keyCode)] { return name }
        return translate(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// 菜单里的按键字符；功能键等无法映射时返回 nil，在标题中显示组合键。
    static func keyEquivalent(_ keyCode: UInt32) -> KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Escape: return .escape
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        default:
            guard specialNames[Int(keyCode)] == nil, let text = translate(keyCode),
                  text.count == 1, let char = text.lowercased().first else { return nil }
            return KeyEquivalent(char)
        }
    }

    private static let specialNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
            kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    /// 用当前 ASCII 键盘布局把键码翻译成字符（中文输入法下也能得到字母）。
    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension KeyCombo {
    @MainActor var display: String { KeyCodeNames.display(self) }
}
