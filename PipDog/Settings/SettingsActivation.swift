import AppKit
import SwiftUI

/// 菜单栏 app（LSUIElement）的设置窗口：打开期间临时切成普通 app（.regular，有 Dock 图标），
/// 窗口才能稳定地出现在最前面并接收键盘；窗口关闭后切回 .accessory。
/// macOS 14+ 的 `NSApp.activate()` 只是请求，前台 app 没让出时会被拒；切换激活策略也是异步生效的。
/// 所以每次显示都先 `orderFrontRegardless()`（不依赖激活，也会盖在别的 app 的窗口上面），再请求激活并成为 key，
/// 下一轮主循环再请求一次（只补这一次，不循环重试）。
/// AppKit 菜单和 ⌘, 共用此处持有的唯一窗口；关窗后把前台还给打开前的 app。不依赖私有标识。
@MainActor
final class SettingsActivation {
    static let shared = SettingsActivation()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// 已经排了下一轮主循环的补一次激活：短时间里连续显示时只排一次
    private var retryScheduled = false
    /// 打开设置前在前台的 app：关掉设置窗口后把前台还给它
    private var previousApp: NSRunningApplication?

    private init() {}

    /// 设置窗口正开着（使用说明关掉时据此决定要不要交还前台）
    var isShowing: Bool { window?.isVisible == true }

    /// 菜单和 ⌘, 共用一个设置窗口。
    /// returningTo：关掉设置后要把前台还给的 app（从使用说明打开时，PipDog 已经因为弹框在前台，记不到原来的 app）。
    func open(returningTo app: NSRunningApplication? = nil) {
        LaunchAtLogin.shared.refresh() // 窗口会复用：每次打开都重读登录项状态
        if let app, app != NSRunningApplication.current { previousApp = app }
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

    /// SwiftUI 的 Settings 场景（只为保留 ⌘, 菜单命令）万一被系统的 showSettingsWindow: 打开：
    /// 立刻收起、关掉那个窗口，改为打开这里的设置窗口，保证只有一个设置窗口。
    func redirect(from other: NSWindow) {
        guard other !== window else { return }
        other.orderOut(nil)
        Task { @MainActor in
            other.close()
            SettingsActivation.shared.open()
        }
    }

    /// open() 新建窗口时调用：只记下窗口、监听关闭；显示统一由 open() 做（这时窗口已经摆好位置）。
    private func attach(_ window: NSWindow) {
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
        if !window.isVisible || window.isMiniaturized { // 刚要出现：记下当前前台的 app，关窗后还给它
            let front = NSWorkspace.shared.frontmostApplication
            if let front, front != NSRunningApplication.current { previousApp = front }
        }
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
        // 把前台还给打开设置前的 app（协作激活：先让出再由它激活）；它已退出或 PipDog 本来就不在前台时不动
        let app = previousApp
        previousApp = nil
        guard NSApp.isActive else { return }
        if let app, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current)
        } else {
            NSApp.deactivate() // 没有可还的 app：至少别让没有窗口的 PipDog 留在前台吞掉按键
        }
    }
}

/// SwiftUI Settings 场景的内容：被放进窗口时转到 SettingsActivation 的设置窗口，自己的窗口关掉。
struct SettingsRedirect: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowAccessor { SettingsActivation.shared.redirect(from: $0) })
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
