import SwiftUI

@main
struct PipDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 设置窗口由 SettingsActivation 自己管；这个场景只为挂 ⌘, 菜单命令，内容万一被打开就转到那个窗口
        Settings {
            SettingsRedirect()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsActivation.shared.open() }.keyboardShortcut(",")
            }
        }
    }
}

/// 使用 AppKit 的菜单打开前回调，保证每次显示前同步读取权限和快捷键。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    /// 菜单栏图标：资源目录里的模板图 StatusIcon（`Design/StatusIcon.swift` 生成），系统按菜单栏深浅着色。
    /// size 是显示尺寸（pt）：菜单栏用 18，欢迎窗口正文里用小一点的。
    static func icon(size: CGFloat = 18) -> NSImage? {
        guard let image = (NSImage(named: "StatusIcon")?.copy() as? NSImage) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        image.accessibilityDescription = "PipDog"
        return image
    }

    override init() {
        super.init()
        statusItem.button?.image = Self.icon()
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
            add(String(localized: "\(KeyCodeNames.symbols(for: settings.config.clickModifiers)) + Double-Click: PiP Area Under Pointer"), to: menu)
        }
        menu.addItem(.separator())
        let settingsItem = add(String(localized: "Settings…"), action: #selector(openSettings), to: menu)
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        let launchAtLogin = LaunchAtLogin.shared
        launchAtLogin.refresh() // 每次打开菜单都读系统的登录项状态
        let launchItem = add(String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), to: menu)
        launchItem.state = launchAtLogin.isEnabled ? .on : .off

        let screenRecording = Permissions.screenRecordingState
        add(String(localized: "\(Permissions.screenRecordingName): \(screenRecording.title)"), action: #selector(screenRecordingGuide),
            enabled: screenRecording != .authorized, to: menu)
        let accessibility = Permissions.hasAccessibility
        let accessibilityTitle = accessibility
            ? String(localized: "Accessibility: Granted")
            : String(localized: "Accessibility: Not Granted (needed for edge parking and modifier + double-click)")
        add(accessibilityTitle, action: #selector(accessibilityGuide), enabled: !accessibility, to: menu)
        menu.addItem(.separator())
        add(String(localized: "Welcome Guide…"), action: #selector(showGuide), to: menu)
        add(String(localized: "About PipDog"), action: #selector(showAbout), to: menu)
        let quit = add(String(localized: "Quit PipDog"), action: #selector(terminate), to: menu)
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
    @objc private func showGuide() { Onboarding.showGuide() }
    @objc private func showAbout() { Onboarding.showAbout() }
    @objc private func toggleLaunchAtLogin() {
        let launchAtLogin = LaunchAtLogin.shared
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled, openSettingsIfNeeded: true)
    }
}
