import AppKit
import ImageIO
import QuickLookUI
import UniformTypeIdentifiers

/// ⌥ + 单击 PiP：把原窗口（或区域）的原尺寸截图存成 PNG，用快速查看（QLPreviewPanel）打开。
/// 截图放在 NSTemporaryDirectory()/PipDog，新截图替换旧截图时删掉旧文件，退出时删掉整个目录。
///
/// QLPreviewPanel 通过响应链找控制者：PiPPanel 实现 accept/begin/endPreviewPanelControl，
/// 并转给这里（数据源）。PipDog 是菜单栏 app，平时不在前台，所以打开前先激活自己；
/// 快速查看关闭时如果 PipDog 仍在前台，就把前台还给打开前的 app。
/// PiP 平时不能成为 key 窗口，只在快速查看期间临时允许（allowsKeyFocus）。快速查看关闭、没能打开、
/// 或 PipDog 失去前台（快速查看被系统收起）时都走 restoreIfClosed：清掉标志、让出 key、把前台还回去。
@MainActor
final class SnapshotPreview: NSObject, QLPreviewPanelDataSource {
    static let shared = SnapshotPreview()

    struct WriteError: LocalizedError {
        var errorDescription: String? { "无法保存截图" }
    }

    private nonisolated static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PipDog", isDirectory: true)
    }

    /// 当前要显示的截图
    private(set) var item: URL?
    /// 为了快速查看而激活 PipDog 之前的前台 app
    private var returnTo: NSRunningApplication?
    /// 当前临时允许成为 key 窗口的 PiP（快速查看的控制者）
    private weak var keyPanel: PiPPanel?

    override init() {
        super.init()
        // 快速查看是 PipDog 的面板，PipDog 失去前台时可能被收起（不一定调用 endPreviewPanelControl）
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SnapshotPreview.shared.restoreIfClosed() } }
        }
    }

    /// ⌥ + 单击时立刻调用：PipDog 不在前台就记下要还前台的 app 并开始激活（激活是异步的，和截图同时进行）。
    func prepare(previousApp: NSRunningApplication?) {
        guard !NSApp.isActive else { return }
        if returnTo == nil, previousApp != NSRunningApplication.current { returnTo = previousApp }
        NSApp.activate()
    }

    /// 保存截图并在 panel 上方打开快速查看（已打开时换成新截图）。
    func present(_ image: CGImage, name: String, from panel: PiPPanel) async throws {
        // PNG 编码放到后台，不卡住主线程
        let url = try await Task.detached { try Self.write(image, name: name) }.value
        if let item, item != url { try? FileManager.default.removeItem(at: item) }
        item = url

        guard let preview = QLPreviewPanel.shared() else {
            restoreIfClosed()
            return
        }
        if !NSApp.isActive {
            if returnTo == nil, let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
                returnTo = front
            }
            NSApp.activate()
            // 激活是异步的：等它生效（最多约 0.3 秒），这样 PiP 能成为主窗口，快速查看找得到控制者
            for _ in 0..<10 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(30)) }
        }
        guard panel.isVisible else { // 等待期间 PiP 被关掉了：快速查看没开的话把前台还回去
            restoreIfClosed()
            return
        }
        if let keyPanel, keyPanel !== panel { keyPanel.allowsKeyFocus = false }
        keyPanel = panel
        panel.allowsKeyFocus = true
        panel.makeKeyAndOrderFront(nil) // 让这个 PiP 成为主窗口，快速查看才能从响应链找到它
        let above = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        if preview.level.rawValue < above.rawValue { preview.level = above } // 不被置顶的 PiP 挡住
        if preview.isVisible {
            preview.reloadData()
            preview.currentPreviewItemIndex = 0
        }
        preview.makeKeyAndOrderFront(nil)
        // 快速查看没能打开（找不到控制者、激活被拒）时，稍后清理，不让小窗一直能抢键盘
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            restoreIfClosed()
        }
    }

    // MARK: - 给 PiPPanel 的控制者回调

    var hasItem: Bool { item != nil }

    func beginControl(_ preview: QLPreviewPanel) {
        preview.dataSource = self
        preview.reloadData()
    }

    func endControl(_ preview: QLPreviewPanel) {
        if preview.dataSource === self { preview.dataSource = nil }
        // 只是换了控制者（点了另一个 PiP）时快速查看还开着；真的关了才把前台还回去
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SnapshotPreview.shared.restoreIfClosed() }
        }
    }

    /// 退出时（以及启动时清掉上次异常退出留下的）删除截图目录。
    nonisolated static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { item as NSURL? }
    }

    // MARK: - 内部

    /// 快速查看已经不可见时（关闭、没打开、被收起）收尾：PiP 恢复成不抢键盘并让出 key，把前台还给之前的 app。
    /// 快速查看还开着时什么都不做。可以重复调用。
    func restoreIfClosed() {
        guard !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
        let panel = keyPanel
        keyPanel = nil
        panel?.allowsKeyFocus = false
        let app = returnTo
        returnTo = nil
        if let app, !app.isTerminated, NSApp.isActive { // 用户已经切到别的 app 了就不动
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current)
        } else if let panel, panel.isKeyWindow {
            // canBecomeKey 变成 false 不会自动让出 key：有设置窗口就交给它，否则让 PipDog 退出前台
            if let other = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is QLPreviewPanel) }) {
                other.makeKeyAndOrderFront(nil)
            } else {
                NSApp.deactivate()
            }
        }
    }

    private nonisolated static func write(_ image: CGImage, name: String) throws -> URL {
        let directory = directory
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw WriteError()
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safeName) \(formatter.string(from: Date())).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WriteError() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError() }
        return url
    }
}
