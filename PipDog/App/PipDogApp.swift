import SwiftUI

@main
struct PipDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { SettingsActivation.shared.open() }.keyboardShortcut(",")
            }
        }
    }
}

/// 使用 AppKit 的菜单打开前回调，保证每次显示前同步读取权限和快捷键。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "PipDog")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu) // 先填一次，不依赖空菜单也会触发回调
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = ShortcutSettings.shared
        for action in ShortcutAction.allCases {
            let item = add(action.title, action: #selector(performPiPAction(_:)), to: menu)
            item.representedObject = action.rawValue
            if let combo = settings.combo(for: action) {
                if let key = KeyCodeNames.keyEquivalent(combo.keyCode) {
                    item.keyEquivalent = String(key.character)
                    item.keyEquivalentModifierMask = KeyCodeNames.flags(fromCarbon: combo.modifiers)
                } else {
                    item.title += "  \(combo.display)"
                }
            }
        }
        if settings.config.clickEnabled {
            menu.addItem(.separator())
            add("\(KeyCodeNames.symbols(for: settings.config.clickModifiers)) + 双击：PiP 鼠标下方的区域", to: menu)
        }
        menu.addItem(.separator())
        let settingsItem = add("设置…", action: #selector(openSettings), to: menu)
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command

        let screenRecording = Permissions.screenRecordingState
        add("屏幕录制：\(screenRecording.rawValue)", action: #selector(screenRecordingGuide),
            enabled: screenRecording != .authorized, to: menu)
        let accessibility = Permissions.hasAccessibility
        let accessibilityTitle = settings.config.clickEnabled
            ? "辅助功能：\(accessibility ? "已授权" : "未授权")"
            : "辅助功能：不需要（双击已关闭）"
        add(accessibilityTitle, action: #selector(accessibilityGuide),
            enabled: settings.config.clickEnabled && !accessibility, to: menu)
        menu.addItem(.separator())
        let quit = add("退出 PipDog", action: #selector(terminate), to: menu)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, enabled: Bool = true, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
        return item
    }

    @objc private func performPiPAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        ShortcutSettings.shared.performAction?(action)
    }

    @objc private func openSettings() { SettingsActivation.shared.open() }
    @objc private func screenRecordingGuide() { Permissions.showAlert(.screenRecording) }
    @objc private func accessibilityGuide() { Permissions.showAlert(.accessibility) }
    @objc private func terminate() { NSApp.terminate(nil) }
}
