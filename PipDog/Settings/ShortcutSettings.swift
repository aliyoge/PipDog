import AppKit
import Carbon.HIToolbox
import Observation

/// 快捷键设置的唯一来源：读写 UserDefaults、注册全局快捷键、录制新快捷键。
@MainActor
@Observable
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    private(set) var config: ShortcutConfig
    /// 每个动作下方显示的红字错误
    private(set) var errors: [ShortcutAction: String] = [:]
    /// 正在录制的动作；录制期间全局快捷键暂时注销
    private(set) var recordingAction: ShortcutAction?

    /// 快捷键按下时执行的动作，由 AppDelegate 设置
    @ObservationIgnored var performAction: ((ShortcutAction) -> Void)?
    @ObservationIgnored private var keyMonitor: Any?
    /// 录制期间：app 失去激活或设置窗口失去焦点就取消录制，避免全局快捷键一直处于注销状态
    @ObservationIgnored private var resignObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaultsKey = "PipDog.shortcutConfig"

    private init() {
        config = Self.load(key: defaultsKey)
    }

    /// 启动时注册已保存的快捷键。
    func activate() {
        for action in register(config) { errors[action] = occupiedMessage(config.hotKeys[action]) }
    }

    func combo(for action: ShortcutAction) -> KeyCombo? { config.hotKeys[action] }

    // MARK: 修改

    /// 设置（或清除，combo 为 nil）一个动作的快捷键。冲突时保留原值并显示错误。
    func assign(_ combo: KeyCombo?, to action: ShortcutAction) {
        errors[action] = nil
        if let combo, !combo.isValidHotKey {
            errors[action] = "至少要包含 ⌘、⌃ 或 ⌥ 中的一个（只有 ⇧ 不行）"
            register(config)
            return
        }
        if let combo, let other = ShortcutAction.allCases.first(where: { $0 != action && config.hotKeys[$0] == combo }) {
            errors[action] = "\(combo.display) 已经用于「\(other.title)」"
            register(config)
            return
        }
        var updated = config
        updated.hotKeys[action] = combo
        if register(updated).contains(action) {
            errors[action] = occupiedMessage(combo)
            register(config)
            return
        }
        save(updated)
    }

    func clear(_ action: ShortcutAction) {
        cancelRecording()
        assign(nil, to: action)
    }

    func setClickEnabled(_ enabled: Bool) {
        var updated = config
        updated.clickEnabled = enabled
        save(updated)
    }

    /// 切换双击所需的某个修饰键；至少保留一个。
    func setClickModifier(_ modifier: ClickModifier, on: Bool) {
        var updated = config
        if on { updated.clickModifiers.insert(modifier.flag) } else { updated.clickModifiers.remove(modifier.flag) }
        guard !updated.clickModifiers.isEmpty else { return }
        save(updated)
    }

    func restoreDefaults() {
        cancelRecording()
        errors = [:]
        let defaults = ShortcutConfig.default
        for action in register(defaults) { errors[action] = occupiedMessage(defaults.hotKeys[action]) }
        save(defaults)
    }

    // MARK: 录制

    func startRecording(_ action: ShortcutAction) {
        cancelRecording()
        errors[action] = nil
        recordingAction = action
        HotKeys.shared.unregisterAll() // 这样当前的组合也能重新录
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { self?.handleRecordedKey(keyCode: keyCode, flags: flags) ?? false }
            return handled ? nil : event
        }
        let cancel: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        let center = NotificationCenter.default
        resignObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: cancel),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main, using: cancel),
        ]
    }

    func cancelRecording() {
        guard recordingAction != nil else { return }
        stopRecording()
        register(config)
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        resignObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resignObservers = []
        recordingAction = nil
    }

    private func handleRecordedKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let action = recordingAction else { return false }
        let mods = flags.intersection([.control, .option, .shift, .command])
        if Int(keyCode) == kVK_Escape && mods.isEmpty {
            cancelRecording()
            return true
        }
        guard !mods.isDisjoint(with: [.control, .option, .command]) else {
            errors[action] = "至少要包含 ⌘、⌃ 或 ⌥ 中的一个（只有 ⇧ 不行）"
            return true
        }
        stopRecording()
        assign(KeyCombo(keyCode: UInt32(keyCode), modifiers: KeyCodeNames.carbonModifiers(from: mods)), to: action)
        return true
    }

    // MARK: 注册与存储

    /// 先注销全部，再按 config 注册；返回注册失败的动作。
    @discardableResult
    private func register(_ config: ShortcutConfig) -> Set<ShortcutAction> {
        HotKeys.shared.unregisterAll()
        var failed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let combo = config.hotKeys[action] else { continue }
            let ok = HotKeys.shared.register(keyCode: Int(combo.keyCode), modifiers: combo.modifiers) { [weak self] in
                self?.performAction?(action)
            }
            if !ok { failed.insert(action) }
        }
        return failed
    }

    private func occupiedMessage(_ combo: KeyCombo?) -> String {
        "\(combo?.display ?? "该快捷键") 已被其他 app 或系统占用，未生效"
    }

    private func save(_ updated: ShortcutConfig) {
        config = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// 读取保存的设置。解码是宽容的（见 ShortcutConfig 的 init(from:)），只有数据整体损坏时才用默认值。
    private static func load(key: String) -> ShortcutConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data)
        else { return .default }
        return config
    }
}
