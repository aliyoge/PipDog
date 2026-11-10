import AppKit
import SwiftUI

/// 菜单栏 app（LSUIElement）的设置窗口：打开期间临时切成普通 app（.regular，有 Dock 图标），
/// 窗口才能稳定地出现在最前面并接收键盘；窗口关闭后切回 .accessory。
/// AppKit 菜单和 ⌘, 共用此处持有的窗口；WindowAccessor 同步窗口生命周期，不依赖私有标识或延时。
@MainActor
final class SettingsActivation {
    static let shared = SettingsActivation()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    /// 菜单和 ⌘, 共用一个设置窗口。
    func open() {
        LaunchAtLogin.shared.refresh() // 窗口会复用：每次打开都重读登录项状态
        willOpen()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "PipDog 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            attach(window)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func willOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 设置界面被放进窗口时调用。
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
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
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
