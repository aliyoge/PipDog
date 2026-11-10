import AppKit
import Carbon.HIToolbox

/// 一个快捷键：虚拟键码 + Carbon 修饰键掩码。
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// 全局快捷键至少要带 ⌘、⌃、⌥ 其中一个，否则会拦截正常打字。
    var isValidHotKey: Bool {
        modifiers & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0
    }

    /// 只用 ⌘（或 ⌘⇧）加普通键：全局注册后会抢走 ⌘C、⌘Q、⌘W、⌘⇧Z 这类全系统常用快捷键。功能键 F1–F20 除外。
    var conflictsWithStandardShortcuts: Bool {
        let all = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
        let mods = modifiers & all
        guard mods == UInt32(cmdKey) || mods == UInt32(cmdKey) | UInt32(shiftKey) else { return false }
        return !Self.functionKeyCodes.contains(Int(keyCode))
    }

    /// 不能用作全局快捷键的原因；可以用时为 nil。
    var validationError: String? {
        if !isValidHotKey { return String(localized: "Include at least one of ⌘, ⌃ or ⌥ (⇧ alone isn't enough)") }
        if conflictsWithStandardShortcuts {
            return String(localized: "⌘ or ⌘⇧ with a regular key would take over common shortcuts like ⌘C, ⌘Q and ⌘W. Add ⌃ or ⌥ (F1–F20 are fine).")
        }
        return nil
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// 可以绑定全局快捷键的动作。
enum ShortcutAction: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case pipWindow, selectRegion, closeAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pipWindow: String(localized: "PiP Current Window")
        case .selectRegion: String(localized: "Select Region to PiP")
        case .closeAll: String(localized: "Close All PiPs")
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
    /// NSEvent.ModifierFlags 的 rawValue（只含 ⌃⌥⇧⌘）
    var clickModifiersRaw: UInt

    var clickModifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: clickModifiersRaw) }
        set { clickModifiersRaw = newValue.intersection([.control, .option, .shift, .command]).rawValue }
    }

    /// 默认：⌃⌥P / ⌃⌥⇧P / ⌃⌥⌫；双击默认 ⌥⇧（⌃ 点击会被当成右键，所以不用 ⌃）。
    static let `default`: ShortcutConfig = {
        let ctrlOpt = UInt32(controlKey) | UInt32(optionKey)
        return ShortcutConfig(
            hotKeys: [
                .pipWindow: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt),
                .selectRegion: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt | UInt32(shiftKey)),
                .closeAll: KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: ctrlOpt),
            ],
            clickEnabled: true,
            clickModifiersRaw: NSEvent.ModifierFlags([.option, .shift]).rawValue)
    }()
}

// 宽容的解码：缺字段用默认值；单个动作解码失败、动作名不认识或快捷键不带修饰键时只丢掉这一项，
// 不会因为一处数据坏了就把整份设置重置。写在 extension 里以保留成员初始化器。
extension ShortcutConfig {
    enum CodingKeys: String, CodingKey {
        case hotKeys, clickEnabled, clickModifiersRaw
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ShortcutConfig.default

        if let stored = try? container.decodeIfPresent([String: Lossy<KeyCombo>].self, forKey: .hotKeys) {
            var hotKeys: [ShortcutAction: KeyCombo] = [:]
            for (name, entry) in stored {
                guard let action = ShortcutAction(rawValue: name), let combo = entry.value, combo.isValidHotKey else { continue }
                hotKeys[action] = combo
            }
            self.hotKeys = hotKeys
        } else {
            hotKeys = fallback.hotKeys
        }

        clickEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .clickEnabled)) ?? fallback.clickEnabled

        let raw = (try? container.decodeIfPresent(UInt.self, forKey: .clickModifiersRaw)) ?? fallback.clickModifiersRaw
        let modifiers = NSEvent.ModifierFlags(rawValue: raw).intersection([.control, .option, .shift, .command])
        clickModifiersRaw = modifiers.isEmpty ? fallback.clickModifiersRaw : modifiers.rawValue
    }
}

/// 解码失败时得到 nil，而不是让外层整个失败。
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
