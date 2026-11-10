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
    /// 画面停住时盖在上面的暂停提示：原 app 被隐藏（隐藏后 ScreenCaptureKit 不再发完整帧），或原窗口最小化。
    /// 原窗口在别的桌面（Space）时不提示：那时抓取可能照常出帧，只是内容不常变，提示会反复闪。
    private let pauseOverlay = PauseOverlay()
    /// 原 app 隐藏的暂停提示正在显示（优先于最小化）
    private var showsHiddenPause = false
    /// 原窗口最小化了
    private var showsMinimizedPause = false
    private var minimizedTimer: Timer?
    private var checkingMinimized = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hoverHider: HoverHider?
    /// 画面缩放倍数（PiPContentView 缩放停下后告诉这里）：抓取分辨率跟着放大
    private var zoom: CGFloat = 1
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
        view.layer?.addSublayer(imageLayer)
        view.imageLayer = imageLayer // frame 由内容视图管（缩放、平移、跟着小窗大小）
        // 子视图从下到上：暂停提示、缩放手柄、×、倍数提示（画面图层 zPosition -1，在它们下面）
        pauseOverlay.frame = view.bounds
        pauseOverlay.autoresizingMask = [.width, .height]
        view.addSubview(pauseOverlay) // 不接收鼠标，单击、拖动、×、缩放手柄照常可用
        // 无边框窗口的边缘缩放不可靠，右下角放一个缩放手柄
        let handleSize = ResizeHandle.size
        let handle = ResizeHandle(frame: NSRect(x: size.width - handleSize, y: 0, width: handleSize, height: handleSize))
        handle.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(handle)
        view.bringChromeToFront()
        view.onClick = { [weak self] modifiers in self?.clicked(modifiers: modifiers) }
        view.onCloseButton = { [weak self] in self?.close() }
        view.onZoomSettled = { [weak self] zoom in
            guard let self else { return }
            self.zoom = zoom
            contentSizeDidSettle()
        }
        contentView = view
        alphaValue = PiPAppearanceSettings.shared.opacity
        let hider = HoverHider(panel: self) { [weak view] point in view?.isOverChrome(screenPoint: point) ?? false }
        view.onPointerEntered = { [weak hider] in hider?.pointerEntered() }
        view.onPointerExited = { [weak hider] in hider?.pointerExited() }
        hoverHider = hider

        capture.onFrame = { [weak self] frame in self?.show(frame) }
        capture.onSourceSizeChange = { [weak self] size in self?.adaptAspect(to: size) }
        capture.onStop = { [weak self] reason in self?.captureEnded(reason) }
        capture.setOutputLimit(pixelSize)
        observeSourceHidden()
    }

    /// 原 app 隐藏 / 取消隐藏（⌘H、Dock，或单击小窗取消隐藏）时显示 / 去掉暂停提示；原 app 退出时结束 PiP
    /// （隐藏期间抓取已暂停，没有别的路径能发现它退出）。
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
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                     queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid == self.source.pid, !self.isClosing else { return }
                let ended = self.onEnded
                self.close()
                ended?("原窗口已关闭，PiP 已结束")
            }
        })
    }

    /// 隐藏时显示暂停提示（画面停在最后一帧，小窗不关）；取消隐藏时重新开始抓取，真的恢复了才去掉提示。
    private func setSourceHidden(_ hidden: Bool) {
        guard !hidden else {
            showsHiddenPause = true
            updatePauseOverlay()
            return
        }
        Task {
            let resumed = await capture.resumeAfterUnhide()
            guard !isClosing, let resumed else { return } // nil：还隐藏着或另一次恢复正在进行
            if resumed {
                showsHiddenPause = false
                updatePauseOverlay()
            } else {
                Feedback.show("无法恢复「\(source.ownerName)」的画面，请再\(WindowClickSettings.shared.mode.title)小窗重试")
            }
        }
    }

    /// 设置里改了单击 / 双击：更新暂停提示里的说法。
    func clickModeDidChange(_ mode: WindowClickMode) {
        updatePauseOverlay()
    }

    private func updatePauseOverlay() {
        let mode = WindowClickSettings.shared.mode
        if showsHiddenPause {
            pauseOverlay.update(text: "原 app 已隐藏，画面暂停\n\(mode.title)小窗恢复")
        } else if showsMinimizedPause {
            pauseOverlay.update(text: "原窗口已最小化，画面暂停\n从程序坞恢复原窗口后继续")
        }
        pauseOverlay.isHidden = !(showsHiddenPause || showsMinimizedPause)
    }

    /// 每秒看一次原窗口是否最小化：窗口在当前桌面上显示就肯定没有；不显示时（最小化、别的桌面、app 隐藏）
    /// 再用 AX 在后台问一次是不是最小化（没有辅助功能权限就问不到，不提示）。原 app 隐藏由通知处理，这里不管。
    private func checkSourceMinimized() {
        guard !isClosing, !checkingMinimized, let onScreen = WindowLocator.isOnScreen(source.id) else { return }
        guard !onScreen else { return setMinimizedPause(false) }
        guard Permissions.hasAccessibility, let bounds = WindowLocator.bounds(of: source.id) else { return }
        checkingMinimized = true
        let pid = source.pid, title = WindowLocator.title(of: source.id)
        Task {
            let minimized = await Task.detached { SourceWindowActivator.isMinimized(pid: pid, bounds: bounds, title: title) }.value
            checkingMinimized = false
            if let minimized { setMinimizedPause(minimized) }
        }
    }

    private func setMinimizedPause(_ minimized: Bool) {
        guard !isClosing, minimized != showsMinimizedPause else { return }
        showsMinimizedPause = minimized
        updatePauseOverlay()
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

    /// 设置里改了不透明度或悬停自动隐藏。隐藏期间不改 alphaValue，恢复时再用新的不透明度。
    func appearanceDidChange() {
        let settings = PiPAppearanceSettings.shared
        hoverHider?.setEnabled(settings.hoverAutoHide)
        if hoverHider?.isHidden != true { alphaValue = settings.opacity }
    }

    /// 悬停隐藏中就恢复（再次 PiP 同一窗口时）
    func revealIfHidden() { hoverHider?.revealIfHidden() }

    func start() async throws {
        orderFrontRegardless()
        hoverHider?.setEnabled(PiPAppearanceSettings.shared.hoverAutoHide)
        minimizedTimer = Timer.scheduledOnCommonModes(interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSourceMinimized() }
        }
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

    /// 抓取用的像素尺寸：面板像素尺寸乘画面缩放倍数（WindowCapture 不会超过原生分辨率和 4096）
    private var pixelSize: CGSize {
        let points = contentView?.bounds.size ?? frame.size
        let factor = backingScaleFactor * zoom
        return CGSize(width: points.width * factor, height: points.height * factor)
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
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        hoverHider?.stop()
        hoverHider = nil
        minimizedTimer?.invalidate()
        minimizedTimer = nil
        imageLayer.contents = nil
        currentFrame = nil
        super.close()
        onClose?()
        onClose = nil
        onEnded = nil
    }

    // MARK: - 单击

    /// 单击或双击（按设置，PiPContentView 已经判断过）切回原窗口（原窗口已在最前时移到屏幕边上）；
    /// ⌥ + 单击用快速查看看原尺寸截图。
    private func clicked(modifiers: NSEvent.ModifierFlags) {
        guard !isClosing else { return }
        if modifiers.contains(.option) {
            showQuickLook()
        } else {
            // 原 app 被隐藏时单击会取消隐藏：立即尝试恢复画面，不等系统通知
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
            // ScreenCaptureKit 的原始错误（英文）只写日志；屏幕录制被拒或运行中被撤销才走权限引导
            NSLog("PipDog: PiP 抓取中途停止：\(error.localizedDescription)")
            if Permissions.isScreenRecordingLost(error) {
                Permissions.showAlert(.screenRecording, afterFailure: true)
            } else if WindowLocator.isOnScreen(source.id) == false {
                ended?("PiP 已结束：原窗口不在当前桌面（最小化或在其他桌面）时系统停止了抓取，恢复原窗口后再 PiP 一次")
            } else {
                ended?("PiP 已结束：画面抓取意外停止，可以再 PiP 一次这个窗口")
            }
        }
    }
}

/// 画面暂停时盖在 PiP 画面上的半透明提示（文字由 PiPPanel 按原因给）。不接收鼠标，事件照常交给下面的内容视图和按钮。
private final class PauseOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    func update(text: String) {
        label.stringValue = text
        needsLayout = true
    }

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
