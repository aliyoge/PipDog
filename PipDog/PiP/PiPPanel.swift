import AppKit
import QuickLookUI
import ScreenCaptureKit

/// 一个置顶、跨 Space 的浮动面板，实时显示某个窗口（或其中一块区域）的画面。
@MainActor
final class PiPPanel: NSPanel, NSWindowDelegate {
    private let capture: WindowCapture
    /// 原窗口（单击切回、⌥ 单击快速查看时用）
    private let source: WindowInfo
    private let imageLayer = CALayer()
    /// 正在显示的帧；保留到下一帧到来，避免它的 IOSurface 被复用
    private var currentFrame: CapturedFrame?
    private var isClosing = false
    /// 原 app 被隐藏时盖在画面上的暂停提示（隐藏后 ScreenCaptureKit 不再发完整帧，画面会停住）
    private let pauseOverlay = PauseOverlay()
    private var workspaceObservers: [NSObjectProtocol] = []
    var onClose: (() -> Void)?
    /// 抓取意外结束（原窗口关闭等）时调用，参数是给用户看的说明
    var onEnded: ((String) -> Void)?

    /// - Parameters:
    ///   - region: 窗口内区域（点，窗口左上角为原点）；nil 表示整个窗口
    ///   - source: 原窗口；它在屏幕上的位置用来决定面板放在哪块屏幕
    ///   - cascadeIndex: 第几个面板，用来错开位置
    init(window target: SCWindow, region: CGRect?, source: WindowInfo, cascadeIndex: Int) {
        capture = WindowCapture(window: target, region: region)
        self.source = source
        let size = Self.panelSize(for: region?.size ?? target.frame.size, isRegion: region != nil)
        let screen = (Geometry.screen(containingTopLeftRect: source.bounds) ?? Geometry.screenUnderMouse ?? NSScreen.main)?
            .visibleFrame ?? .zero
        let offset = CGFloat(cascadeIndex % 8) * 28
        let origin = NSPoint(x: max(screen.minX, screen.maxX - size.width - 20 - offset),
                             y: min(screen.maxY - size.height, screen.minY + 20 + offset))

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false // NSPanel 默认 true：PipDog 一失去激活（框选结束、设置窗口切走）面板就会消失
        isMovableByWindowBackground = false // 拖动由 PiPContentView 区分单击后自己发起
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear // 透明窗口 + 圆角图层，四角才不会露出黑色方角
        isReleasedWhenClosed = false
        contentAspectRatio = size
        delegate = self // 自己接收缩放结束、换屏等通知

        let view = PiPContentView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = view.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        // 无边框窗口的边缘缩放不可靠，右下角放一个缩放手柄
        let handleSize = ResizeHandle.size
        let handle = ResizeHandle(frame: NSRect(x: size.width - handleSize, y: 0, width: handleSize, height: handleSize))
        handle.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(handle)
        pauseOverlay.frame = view.bounds
        pauseOverlay.autoresizingMask = [.width, .height]
        view.addSubview(pauseOverlay) // 不接收鼠标，单击、拖动、×、缩放手柄照常可用
        view.onClick = { [weak self] modifiers in self?.clicked(modifiers: modifiers) }
        view.onCloseButton = { [weak self] in self?.close() }
        contentView = view

        capture.onFrame = { [weak self] frame in self?.show(frame) }
        capture.onSourceSizeChange = { [weak self] size in self?.adaptAspect(to: size) }
        capture.onStop = { [weak self] reason in self?.captureEnded(reason) }
        capture.setOutputLimit(pixelSize)
        observeSourceHidden()
    }

    /// 原 app 隐藏 / 取消隐藏（我们的单击、⌘H、Dock 都算）时显示 / 去掉暂停提示。
    private func observeSourceHidden() {
        setSourceHidden(NSRunningApplication(processIdentifier: source.pid)?.isHidden ?? false)
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool)] = [
            (NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false),
        ]
        workspaceObservers = pairs.map { name, hidden in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, pid == self.source.pid else { return }
                    self.setSourceHidden(hidden)
                }
            }
        }
    }

    /// 隐藏时显示暂停提示（画面停在最后一帧，小窗不关）；取消隐藏时去掉提示并重新开始抓取。
    private func setSourceHidden(_ hidden: Bool) {
        pauseOverlay.isHidden = !hidden
        if !hidden { Task { await capture.resumeAfterUnhide() } }
    }

    /// 面板初始大小：保持源的宽高比。整窗默认宽 360；区域尽量按原尺寸显示，但限制在 160…480。
    private static func panelSize(for source: CGSize, isRegion: Bool) -> NSSize {
        let aspect = source.height / max(source.width, 1)
        var width: CGFloat = isRegion ? min(max(source.width, 160), 480) : 360
        var height = width * aspect
        if height > 480 {
            height = 480
            width = height / max(aspect, 0.01)
        }
        return NSSize(width: width, height: height)
    }

    func start() async throws {
        orderFrontRegardless()
        try await capture.start(fps: CaptureSettings.shared.frameRate)
    }

    /// 把新的帧率应用到正在运行的抓取。
    func setFrameRate(_ fps: Int) {
        capture.setFrameRate(fps)
    }

    /// 面板缩放结束（手柄、系统边缘缩放、跟随源宽高比）或换到像素比例不同的屏幕后调用：
    /// 抓取分辨率跟着面板的像素尺寸走，不按源窗口的原生分辨率抓。
    func contentSizeDidSettle() {
        guard !isClosing else { return }
        capture.setOutputLimit(pixelSize)
        invalidateShadow()
    }

    private var pixelSize: CGSize {
        let points = contentView?.bounds.size ?? frame.size
        return CGSize(width: points.width * backingScaleFactor, height: points.height * backingScaleFactor)
    }

    func windowDidEndLiveResize(_ notification: Notification) { contentSizeDidSettle() }
    func windowDidChangeBackingProperties(_ notification: Notification) { contentSizeDidSettle() }

    /// 只在打开快速查看期间为 true（由 SnapshotPreview 设置和清除）：快速查看要从 key / 主窗口的响应链找控制者。
    /// 平时 PiP 不成为 key 窗口，按下、拖动、单击都不会抢走用户正在打字的 app 的键盘。
    var allowsKeyFocus = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    /// 快速查看从主窗口的响应链找控制者，PiP 要能成为主窗口
    override var canBecomeMain: Bool { true }

    /// 唯一的关闭流程：停止抓取（移除输出）→ 关窗 → 通知 PiPManager 移除。可以重复调用。
    override func close() {
        guard !isClosing else { return }
        isClosing = true
        let capture = capture
        Task { await capture.stop() }
        SourceWindowActivator.restoreIfStashed(pid: source.pid, windowID: source.id) // 原窗口还停在屏幕边上就放回去
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        imageLayer.contents = nil
        currentFrame = nil
        super.close()
        onClose?()
        onClose = nil
        onEnded = nil
    }

    // MARK: - 单击

    /// 单击切回原窗口（原窗口已在最前时隐藏原 app）；⌥ + 单击用快速查看看原尺寸截图。
    private func clicked(modifiers: NSEvent.ModifierFlags) {
        guard !isClosing else { return }
        if modifiers.contains(.option) {
            showQuickLook()
        } else {
            // 自己隐藏 / 显示时立即更新提示，不等系统通知
            if let hidden = SourceWindowActivator.toggle(pid: source.pid, windowID: source.id, appName: source.ownerName) {
                setSourceHidden(hidden)
            }
        }
    }

    private func showQuickLook() {
        // 趁刚收到点击先开始激活 PipDog（截图要一点时间），记下要还前台的 app
        SnapshotPreview.shared.prepare(previousApp: NSWorkspace.shared.frontmostApplication)
        Task {
            do {
                let image = try await capture.snapshot()
                guard !isClosing else {
                    SnapshotPreview.shared.restoreIfClosed()
                    return
                }
                try await SnapshotPreview.shared.present(image, name: source.ownerName, from: self)
            } catch WindowCapture.SnapshotError.busy {
                Feedback.show("快速查看失败：\(WindowCapture.SnapshotError.busy.localizedDescription)") // 上一次还在进行，前台由它负责
            } catch let error as WindowCapture.SnapshotError {
                SnapshotPreview.shared.restoreIfClosed()
                Feedback.show("快速查看失败：\(error.localizedDescription)")
            } catch let error as SnapshotPreview.WriteError {
                SnapshotPreview.shared.restoreIfClosed()
                Feedback.show("快速查看失败：\(error.localizedDescription)")
            } catch {
                SnapshotPreview.shared.restoreIfClosed()
                // ScreenCaptureKit 的原始错误（英文）不直接给用户看；明确是屏幕录制被拒才走权限引导
                NSLog("PipDog: 快速查看截图失败：\(error.localizedDescription)")
                if Permissions.isScreenRecordingError(error) {
                    Permissions.showAlert(.screenRecording, afterFailure: true)
                } else {
                    Feedback.show("快速查看失败：原窗口暂时无法截图，请稍后再试")
                }
            }
        }
    }

    // MARK: - 快速查看控制者（QLPreviewPanel 通过响应链在主线程调用；方法声明在 NSObject 分类里，不带隔离）

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { SnapshotPreview.shared.hasItem }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { SnapshotPreview.shared.beginControl(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { SnapshotPreview.shared.endControl(panel) }
    }

    // MARK: - 内部

    private func show(_ frame: CapturedFrame) {
        let isFirst = currentFrame == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 关掉 contents 变化的隐式淡入动画
        imageLayer.contents = frame.surface
        CATransaction.commit()
        currentFrame = frame
        if isFirst { invalidateShadow() }
    }

    /// 源尺寸变化后按新宽高比调整面板，保持宽度和左上角不变（太高时缩小宽度）。
    private func adaptAspect(to source: CGSize) {
        guard source.width >= 1, source.height >= 1 else { return }
        contentAspectRatio = source
        var rect = frame
        let top = rect.maxY
        var width = rect.width
        var height = width * source.height / source.width
        let maxHeight = (screen?.visibleFrame.height ?? 900) * 0.8
        if height > maxHeight {
            height = maxHeight
            width = height * source.width / source.height
        }
        rect.size = NSSize(width: width, height: height)
        rect.origin.y = top - height
        setFrame(rect, display: true)
        contentSizeDidSettle()
    }

    private func captureEnded(_ reason: WindowCapture.StopReason) {
        // 保险：原 app 只是被隐藏时不关小窗，暂停等它回来
        if let app = NSRunningApplication(processIdentifier: source.pid), !app.isTerminated, app.isHidden {
            setSourceHidden(true)
            capture.pauseUntilShown()
            return
        }
        let ended = onEnded
        close()
        switch reason {
        case .windowClosed:
            ended?("原窗口已关闭，PiP 已结束")
        case .failed(let error):
            // ScreenCaptureKit 的原始错误（英文）只写日志；明确是屏幕录制被拒才走权限引导
            NSLog("PipDog: PiP 抓取中途停止：\(error.localizedDescription)")
            if Permissions.isScreenRecordingError(error) {
                Permissions.showAlert(.screenRecording, afterFailure: true)
            } else {
                ended?("PiP 已结束：画面抓取意外停止")
            }
        }
    }
}

/// 原 app 被隐藏时盖在 PiP 画面上的半透明提示。不接收鼠标，事件照常交给下面的内容视图和按钮。
private final class PauseOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "原 app 已隐藏，画面暂停\n单击小窗恢复")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let width = max(bounds.width - 16, 1)
        let height = min(label.sizeThatFits(NSSize(width: width, height: bounds.height)).height, bounds.height)
        label.frame = NSRect(x: 8, y: (bounds.height - height) / 2, width: width, height: height)
    }
}
