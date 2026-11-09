import AppKit
import Carbon.HIToolbox

/// 一个快捷键：虚拟键码 + Carbon 修饰键掩码。
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// 可以绑定全局快捷键的动作。
enum ShortcutAction: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case pipWindow, selectRegion, closeAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pipWindow: "PiP 当前窗口"
        case .selectRegion: "框选区域"
        case .closeAll: "关闭所有 PiP"
        }
    }
}

/// 双击触发可选的修饰键。
enum ClickModifier: CaseIterable, Identifiable, Sendable {
    case control, option, shift, command

    var id: Self { self }
    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }
}

/// 所有快捷键设置，整体以 JSON 存进 UserDefaults。没有键的动作表示快捷键已清除。
struct ShortcutConfig: Codable, Equatable, Sendable {
    var hotKeys: [ShortcutAction: KeyCombo]
    var clickEnabled: Bool
    /// NSEvent.ModifierFlags 的 rawValue
    var clickModifiersRaw: UInt

    var clickModifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: clickModifiersRaw) }
        set { clickModifiersRaw = newValue.rawValue }
    }

    static let `default`: ShortcutConfig = {
        let ctrlOpt = UInt32(controlKey) | UInt32(optionKey)
        return ShortcutConfig(
            hotKeys: [
                .pipWindow: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt),
                .selectRegion: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt | UInt32(shiftKey)),
                .closeAll: KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: ctrlOpt),
            ],
            clickEnabled: true,
            clickModifiersRaw: NSEvent.ModifierFlags([.control, .option]).rawValue)
    }()
}
