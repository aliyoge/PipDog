import AppKit
import SwiftUI

/// 使用说明：第一次启动时显示一次（UserDefaults 记下已显示），菜单「使用说明…」可以再看。
/// 用一个 SwiftUI 欢迎窗口（`WelcomeView`），内容按当前设置生成（快捷键、单击 / 双击、修饰键 + 双击、悬停隐藏、权限状态）。
/// 只有一个窗口：再次打开时刷新内容并拿到最前面。关窗后把前台还给打开前的 app；点「打开设置」时交给设置窗口。
/// 「关于 PipDog」用一个带版本号的 NSAlert。
@MainActor
enum Onboarding {
    private static let shownKey = "PipDog.onboardingShown"

    private static var window: NSWindow?
    private static var hostingView: NSHostingView<WelcomeView>?
    /// 打开欢迎窗口前在前台的 app：关窗后还给它
    private static var previousApp: NSRunningApplication?
    /// 点了「打开设置」：关窗后打开设置窗口
    private static var openSettingsOnClose = false
    /// 第一次启动时：欢迎窗口关掉后再继续后面的启动提示
    private static var onClose: (@MainActor () -> Void)?

    /// 第一次启动时显示使用说明，关掉后调用 completion；之前显示过就直接调用 completion。
    static func showOnFirstLaunch(then completion: @escaping @MainActor () -> Void) {
        guard !UserDefaults.standard.bool(forKey: shownKey) else {
            completion()
            return
        }
        UserDefaults.standard.set(true, forKey: shownKey)
        onClose = completion
        showGuide()
    }

    /// 菜单「使用说明…」：窗口已开着时刷新内容并拿到最前面。
    static func showGuide() {
        let window = window ?? makeWindow()
        if !window.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        }
        hostingView?.rootView = WelcomeView(info: currentInfo(), onOpenSettings: openSettings, onStart: close)
        if let size = hostingView?.fittingSize { window.setContentSize(size) }
        if !window.isVisible { window.center() }
        // 菜单栏 app：先放到最上面（激活被拒时也看得见），再请求激活并成为 key（回车、Esc 才有效）
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 菜单「关于 PipDog」
    static func showAbout() {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "PipDog"
        alert.informativeText = "版本 \(version)（\(build)）\n把任意窗口或其中一块区域变成置顶的实时小窗。"
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.layout()
        alert.window.orderFrontRegardless()
        _ = alert.runModal()
        handBackActivation(to: previous)
    }

    // MARK: 窗口

    private static func makeWindow() -> NSWindow {
        let window = WelcomeWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                                   styleMask: [.titled, .closable, .fullSizeContentView],
                                   backing: .buffered, defer: true)
        window.title = "欢迎使用 PipDog"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let hosting = NSHostingView(rootView: WelcomeView(info: currentInfo()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        window.contentView = background

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Onboarding.didClose() }
        }
        self.window = window
        hostingView = hosting
        return window
    }

    private static func openSettings() {
        openSettingsOnClose = true
        close()
    }

    private static func close() {
        window?.close()
    }

    private static func didClose() {
        let app = previousApp
        previousApp = nil
        if openSettingsOnClose {
            openSettingsOnClose = false
            SettingsActivation.shared.open(returningTo: app) // 关掉设置后前台回到打开说明前的 app
        } else {
            handBackActivation(to: app)
        }
        let completion = onClose
        onClose = nil
        completion?()
    }

    /// 关掉窗口或提示框后把前台还给之前的 app（和设置窗口关闭时一样）；设置或欢迎窗口还开着时不还。
    private static func handBackActivation(to app: NSRunningApplication?) {
        guard NSApp.isActive, !SettingsActivation.shared.isShowing, window?.isVisible != true else { return }
        if let app, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current)
        } else {
            NSApp.deactivate()
        }
    }

    // MARK: 内容

    /// 按当前设置生成欢迎窗口内容。
    private static func currentInfo() -> WelcomeInfo {
        let settings = ShortcutSettings.shared
        let click = WindowClickSettings.shared.mode.title
        let icons: [ShortcutAction: String] = [.pipWindow: "pip.enter", .selectRegion: "rectangle.dashed", .closeAll: "pip.remove"]
        var shortcuts = ShortcutAction.allCases.map { action in
            WelcomeInfo.Shortcut(icon: icons[action] ?? "keyboard", title: action.title,
                                 keys: settings.combo(for: action).map(keys(of:)) ?? [])
        }
        if settings.config.clickEnabled {
            shortcuts.append(.init(icon: "cursorarrow.click.2", title: "PiP 鼠标下方的区域",
                                   keys: KeyCodeNames.symbols(for: settings.config.clickModifiers).map(String.init),
                                   suffix: "双击"))
        }
        let gestures: [WelcomeInfo.Gesture] = [
            .init(icon: "macwindow", action: "切回原窗口", gesture: click),
            .init(icon: "arrow.right.to.line", action: "停到屏幕边 / 移回", gesture: "原窗口在前时再\(click)"),
            .init(icon: "eye", action: "快速查看", gesture: "⌥ 单击"),
            .init(icon: "plus.magnifyingglass", action: "放大画面", gesture: "滚动 / 捏合"),
            .init(icon: "arrow.counterclockwise", action: "恢复原大小", gesture: "⌘ 单击"),
            .init(icon: "hand.draw", action: "移动 / 平移", gesture: "拖动"),
            .init(icon: "arrow.up.left.and.arrow.down.right", action: "调整大小", gesture: "拖右下角"),
            .init(icon: "xmark.circle", action: "关闭小窗", gesture: "左上角 ×"),
        ]
        let screenState: WelcomeInfo.Permission.State = switch Permissions.screenRecordingState {
        case .authorized: .granted
        case .restartRequired: .restartRequired
        case .notAuthorized: .missing
        }
        return WelcomeInfo(
            icon: NSApp.applicationIconImage,
            menuBarIcon: StatusMenu.icon(size: 15),
            shortcuts: shortcuts,
            gestures: gestures,
            hoverNote: PiPAppearanceSettings.shared.hoverAutoHide ? "鼠标停在小窗上约 1.5 秒会淡出，单独按一下 ⌥ 恢复" : nil,
            permissions: [
                .init(icon: "rectangle.dashed.badge.record", name: Permissions.screenRecordingName,
                      note: "实时显示画面，第一次 PiP 时请求", state: screenState),
                .init(icon: "accessibility", name: "辅助功能",
                      note: "把原窗口移到屏幕边上、修饰键 + 双击，用到时再引导",
                      state: Permissions.hasAccessibility ? .granted : .missing),
            ])
    }

    /// 快捷键拆成一个个键帽：修饰键各一个，最后是主键。
    private static func keys(of combo: KeyCombo) -> [String] {
        KeyCodeNames.symbols(for: KeyCodeNames.flags(fromCarbon: combo.modifiers)).map(String.init)
            + [KeyCodeNames.keyName(combo.keyCode)]
    }
}

/// 欢迎窗口：Esc 关闭。
private final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
