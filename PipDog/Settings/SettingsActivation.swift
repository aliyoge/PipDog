import AppKit
import SwiftUI

/// 菜单栏 app（LSUIElement）的设置窗口：打开期间临时切成普通 app（.regular，有 Dock 图标），
/// 窗口才能稳定地出现在最前面并接收键盘；窗口关闭后切回 .accessory。
/// macOS 14+ 的 `NSApp.activate()` 只是请求，前台 app 没让出时会被拒；切换激活策略也是异步生效的。
/// 所以每次显示都先 `orderFrontRegardless()`（不依赖激活，也会盖在别的 app 的窗口上面），再请求激活并成为 key，
/// 下一轮主循环再请求一次（只补这一次，不循环重试）。
/// AppKit 菜单和 ⌘, 共用此处持有的窗口；WindowAccessor 同步窗口生命周期，不依赖私有标识。
@MainActor
final class SettingsActivation {
    static let shared = SettingsActivation()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// 已经排了下一轮主循环的补一次激活：同一轮里 open() 和 attach() 都显示窗口时只排一次
    private var retryScheduled = false

    private init() {}

    /// 菜单和 ⌘, 共用一个设置窗口。
    func open() {
        LaunchAtLogin.shared.refresh() // 窗口会复用：每次打开都重读登录项状态
        if let window {
            show(window)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "PipDog 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        attach(window)
        show(window)
    }

    /// 设置界面被放进窗口时调用（WindowAccessor，以及 open() 新建窗口时）：只记下窗口、监听关闭。
    /// 不在这里显示：新建窗口时它在 NSWindow 初始化期间就会被调用，那时还没摆好位置；显示统一由 open() 做。
    func attach(_ window: NSWindow) {
        if self.window !== window {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { SettingsActivation.shared.didClose() }
            }
        }
    }

    private func show(_ window: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless() // 激活被拒时也在最上面，不用点 Dock 图标
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard !retryScheduled else { return }
        retryScheduled = true
        // 激活策略切换是异步的：下一轮主循环再请求一次激活，避免第一次请求在切换完成前被丢掉
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SettingsActivation.shared.retryActivation() }
        }
    }

    private func retryActivation() {
        retryScheduled = false
        guard let window, window.isVisible else { return } // 这期间已经关掉了
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func didClose() {
        ShortcutSettings.shared.cancelRecording()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 把 SwiftUI 视图所在的 NSWindow 交给回调。
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView { AccessorView(onWindow: onWindow) }
    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        private let onWindow: @MainActor (NSWindow) -> Void

        init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
