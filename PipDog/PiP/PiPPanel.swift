import AppKit
import QuickLookUI
import ScreenCaptureKit

/// 一个置顶、跨 Space 的浮动面板，实时显示某个窗口（或其中一块区域）的画面。
@MainActor
final class PiPPanel: NSPanel, NSWindowDelegate {
    /// 抓取会给源 app 退出后重建一次（重连），所以不是 let
    private var capture: WindowCapture
    /// 原窗口（单击切回、⌥ 单击快速查看时用）；源 app 重启重连后会换成新窗口
    private var source: WindowInfo
    /// 原 app 的 bundle ID：按 app 记住帧率、重连轮询、Chromium 提示都用它（取不到时为 nil）
    let sourceBundleID: String?
    /// 用户要的区域（窗口内坐标，点）；重连时按新窗口裁剪后再重建抓取（整窗时为 nil）
    private(set) var sourceRegion: CGRect?
    /// 源窗口最近一次的标题和大小：app 退出后按它们找重启后的窗口
    private var sourceTitle: String?
    private var sourceWindowSize: CGSize
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
    /// 每秒检查原窗口是否最小化，以及本面板是否被遮挡 / 不在当前桌面
    private var monitorTimer: Timer?
    private var checkingMinimized = false
    /// 控制条上显示的帧率（启动时和设置变化时更新）
    private var frameRate = CaptureSettings.defaultFrameRate
    /// 用户在控制条上暂停：和「原 app 隐藏」共用 pauseUntilShown / resumeAfterUnhide 这套语义
    private var userPaused = false
    /// 等待源 app 重启中（面板不关，画面是占位提示）
    private var reconnector: SourceWindowReconnector?
    /// 正在用重启后的新窗口重建抓取（防重入）
    private var isStartingReconnectCapture = false
    /// 流因为源窗口不在当前桌面而停掉（不是最小化）：窗口回到当前桌面后自动重新开始抓取
    private var isWaitingForSourceReturn = false
    /// 取消最小化后正在尝试重新开始抓取
    private var isResumingAfterMinimize = false
    /// Chromium 停帧可疑信号：只在画面已经停住时才去看源窗口可见性
    private var chromiumHint = ChromiumRenderHint()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hoverHider: HoverHider?
    var onClose: (() -> Void)?
    /// 重连成功、面板换成新窗口时调用（旧窗口 ID、新窗口 ID、新进程 pid）：PiPManager 据此换 key、迁移停放记录
    var onReconnect: ((CGWindowID, CGWindowID, pid_t) -> Void)?
    /// 抓取意外结束（原窗口关闭等）时调用，参数是给用户看的说明
    var onEnded: ((String) -> Void)?
    /// 拖动中算吸附后的位置（PiPManager 注入：要看面板所在屏幕和其他面板）
    var resolveDragFrame: ((CGRect, NSEvent.ModifierFlags) -> CGRect)?
    /// 拖动结束、位置定了才调用（PiPManager 注入）：参数是面板左上角的屏幕坐标
    var onMoved: ((NSPoint) -> Void)?
    /// 面板大小变了（缩放手柄 / 系统边缘缩放 / 跟随源宽高比）时调用：增强模式要更新悬停按键的命中区
    var onGeometryChanged: (() -> Void)?

    /// 内容视图（拖动、缩放、控制条都在它上面）
    private var pipView: PiPContentView? { contentView as? PiPContentView }

    /// - Parameters:
    ///   - region: 窗口内区域（点，窗口左上角为原点）；nil 表示整个窗口
    ///   - source: 原窗口；它在屏幕上的位置用来决定面板放在哪块屏幕
    ///   - cascadeIndex: 第几个新面板，用来级联错开位置
    ///   - restoredTopLeft: 这个 PiP 上次的左上角位置（没有记过时为 nil，按 cascadeIndex 级联）
    init(window target: SCWindow, region: CGRect?, source: WindowInfo, cascadeIndex: Int, restoredTopLeft: CGPoint?) {
        capture = WindowCapture(window: target, region: region)
        self.source = source
        sourceBundleID = target.owningApplication?.bundleIdentifier
        sourceRegion = region
        sourceTitle = WindowLocator.title(of: target.windowID)
        sourceWindowSize = target.frame.size
        let size = Self.panelSize(for: region?.size ?? target.frame.size, isRegion: region != nil)
        let screen = (Geometry.screen(containingTopLeftRect: source.bounds) ?? Geometry.screenUnderMouse ?? NSScreen.main)?
            .visibleFrame ?? .zero
        let origin = restoredTopLeft.map {
            // 记住的位置在屏幕变化后可能已经看不见：和某块屏幕有交集就原样用，否则收进最近那块屏幕的可见区域
            SnappingGeometry.restoredOrigin(topLeft: $0, size: size,
                                           screenFrames: NSScreen.screens.map(\.frame),
                                           visibleFrames: NSScreen.screens.map(\.visibleFrame))
        } ?? SnappingGeometry.cascadeOrigin(size: size, index: cascadeIndex, in: screen)

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

        let view = PiPContentView(frame: NSRect(origin: .zero, size: size), baseRect: capture.baseRect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        view.layer?.addSublayer(imageLayer)
        view.imageLayer = imageLayer // 永远和内容视图一样大（采集端已经裁剪好，1:1 显示）
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
        view.onDragFrame = { [weak self] frame, modifiers in self?.resolveDragFrame?(frame, modifiers) ?? frame }
        view.onDragEnded = { [weak self] frame in self?.onMoved?(NSPoint(x: frame.minX, y: frame.maxY)) }
        view.onRegionSettled = { [weak self] region in self?.capture.setVisibleRegion(region) }
        // 控制条只上报告诉面板该做什么，状态一律由 updateControlBar 单向灌进去
        view.controlBar.onTogglePause = { [weak self] in self?.toggleUserPause() }
        view.controlBar.onCycleFrameRate = { [weak self] in self?.cycleFrameRate() }
        view.controlBar.onResetZoom = { [weak self] in self?.pipView?.resetZoom() }
        view.controlBar.onToggleHoverAutoHide = { [weak self] in self?.toggleHoverAutoHide() }
        view.controlBar.onClose = { [weak self] in self?.close() }
        contentView = view
        alphaValue = PiPAppearanceSettings.shared.opacity
        let hider = HoverHider(panel: self) { [weak view] point in view?.isOverChrome(screenPoint: point) ?? false }
        view.onPointerEntered = { [weak hider] in hider?.pointerEntered() }
        view.onPointerExited = { [weak hider] in hider?.pointerExited() }
        hoverHider = hider

        wireCapture(capture)
        observeSourceHidden()
        updateControlBar()
    }

    /// 抓取回调：首次抓取和源 app 重启后的新抓取用同一套，免得两边逐渐不一致。
    private func wireCapture(_ capture: WindowCapture) {
        capture.onFrame = { [weak self] frame in self?.show(frame) }
        capture.onSourceSizeChange = { [weak self] size in self?.adaptAspect(to: size) }
        capture.onBaseRectChange = { [weak self] rect in (self?.contentView as? PiPContentView)?.updateBaseRect(rect) }
        capture.onStop = { [weak self] reason in self?.captureEnded(reason) }
        capture.onRendererStalled = { [weak self] in self?.rendererStalled() }
        capture.setOutputLimit(pixelSize)
    }

    /// 原 app 隐藏 / 取消隐藏（⌘H、Dock，或单击小窗取消隐藏）时显示 / 去掉暂停提示；原 app 退出时等它重启后重连
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
                // 源 app 退出：小窗不关，等它重启后重连；等不了（没 bundle ID）才照常结束
                guard !self.beginReconnect() else { return }
                let ended = self.onEnded
                self.close()
                ended?(String(localized: "The source window was closed, so the PiP ended"))
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
        guard showsHiddenPause else { return } // 不是从「隐藏」回来的（例如用户自己在控制条上暂停）：不碰抓取
        guard !userPaused else { // 用户暂停着：原 app 已经不隐藏了，画面继续停着，等他点继续
            showsHiddenPause = false
            updatePauseOverlay()
            return
        }
        Task {
            let resumed = await capture.resumeAfterUnhide()
            guard !isClosing, let resumed else { return } // nil：还隐藏着或另一次恢复正在进行
            if resumed {
                showsHiddenPause = false
                updatePauseOverlay()
                pauseAgainIfNeeded() // 恢复期间用户又暂停 / 窗口最小化了：把流再停上
            } else {
                Feedback.show(WindowClickSettings.shared.mode == .single
                    ? String(localized: "Couldn't resume “\(source.ownerName)”. Click the PiP to try again.")
                    : String(localized: "Couldn't resume “\(source.ownerName)”. Double-click the PiP to try again."))
            }
        }
    }

    /// 设置里改了单击 / 双击：更新暂停提示里的说法。
    func clickModeDidChange(_ mode: WindowClickMode) {
        updatePauseOverlay()
    }

    private func updatePauseOverlay() {
        let mode = WindowClickSettings.shared.mode
        if reconnector != nil {
            pauseOverlay.update(text: String(localized: "Waiting for “\(source.ownerName)” to restart\nThe PiP reconnects when its window is back"))
        } else if showsHiddenPause {
            pauseOverlay.update(text: mode == .single
                ? String(localized: "Source app is hidden; picture paused\nClick the PiP to resume")
                : String(localized: "Source app is hidden; picture paused\nDouble-click the PiP to resume"))
        } else if showsMinimizedPause {
            pauseOverlay.update(text: String(localized: "Source window is minimized; picture paused\nRestore it from the Dock to continue"))
        } else if userPaused {
            pauseOverlay.update(text: String(localized: "Picture paused\nClick the play button in the toolbar to resume"))
        }
        pauseOverlay.isHidden = !(reconnector != nil || showsHiddenPause || showsMinimizedPause || userPaused)
        updateControlBar() // 重连 / 隐藏 / 最小化期间控制条的暂停按钮不可用
    }

    /// 每秒看一次原窗口：位置大小和标题顺手记下来（重连时要用），再看是否最小化。
    /// 窗口在当前桌面上显示就肯定没有最小化；不显示时（最小化、别的桌面、app 隐藏）
    /// 再用 AX 在后台问一次是不是最小化（没有辅助功能权限就问不到，不提示）。原 app 隐藏由通知处理，这里不管。
    private func checkSourceMinimized() {
        guard !isClosing, reconnector == nil, !checkingMinimized else { return }
        guard let snapshot = WindowLocator.snapshot(of: source.id) else {
            // 用户暂停 / 最小化暂停时抓取侧的轮询已经拆掉，窗口被关掉不会自己报错：补上和 captureEnded(.windowClosed) 一样的结束流程
            if userPaused || showsMinimizedPause { captureEnded(.windowClosed) }
            return
        }
        sourceWindowSize = snapshot.bounds.size
        if let title = snapshot.title, !title.isEmpty { sourceTitle = title }
        guard !snapshot.isOnScreen else {
            if isWaitingForSourceReturn { // 源窗口回到当前桌面：重新开始刚才被系统停掉的抓取
                isWaitingForSourceReturn = false
                resumePausedCapture()
            }
            return setMinimizedPause(false)
        }
        guard Permissions.hasAccessibility else { return }
        checkingMinimized = true
        let pid = source.pid, bounds = snapshot.bounds, title = snapshot.title
        Task {
            let minimized = await Task.detached { SourceWindowActivator.isMinimized(pid: pid, bounds: bounds, title: title) }.value
            checkingMinimized = false
            if let minimized { setMinimizedPause(minimized) }
        }
    }

    /// 面板被其他窗口完全遮挡、或不在当前桌面（切到别的 Space、全屏）时，把抓取降到 1 fps；重新可见后立即恢复。
    /// 关掉设置里的开关时这里也会把状态清掉（下一次检查生效）。
    private func checkPiPVisibility() {
        guard !isClosing, reconnector == nil else { return }
        guard CaptureSettings.shared.pauseWhenObscured else { return capture.setOccluded(false) }
        capture.setOccluded(!PiPVisibility.isVisible(self))
    }

    private func setMinimizedPause(_ minimized: Bool) {
        guard !isClosing else { return }
        capture.setSourceMinimized(minimized) // 最小化时没有新帧是正常的，不算渲染卡顿
        guard minimized != showsMinimizedPause else { return }
        showsMinimizedPause = minimized
        updatePauseOverlay()
        if !minimized { resumePausedCapture() }
    }

    /// 取消最小化、或源窗口回到当前桌面后自动恢复画面：期间 ScreenCaptureKit 可能已经停了流，
    /// 不点小窗也应该自己接上。
    private func resumePausedCapture() {
        guard !isClosing, !showsHiddenPause, !userPaused, capture.isPaused, !isResumingAfterMinimize else { return }
        isResumingAfterMinimize = true
        Task {
            let resumed = await capture.resumeAfterUnhide()
            isResumingAfterMinimize = false
            guard !isClosing, resumed == true else { return }
            showsMinimizedPause = false
            updatePauseOverlay()
            pauseAgainIfNeeded() // 恢复期间用户又暂停 / 原 app 又隐藏 / 窗口又最小化了：把流再停上
        }
    }

    /// 恢复完成时状态可能又变了（用户点了暂停、原 app 又隐藏或最小化、开始重连）：把刚开起来的流再停上，
    /// 免得暂停遮罩下面画面还在动。
    private func pauseAgainIfNeeded() {
        guard !isClosing, reconnector == nil else { return }
        guard userPaused || showsHiddenPause || showsMinimizedPause else { return }
        capture.pauseUntilShown()
    }

    /// Chromium / Electron 的 app 把窗口移到别的 Space、或被完全遮挡后可能不再重画，ScreenCaptureKit
    /// 只能拿到最后一帧。画面一直在动时什么都不查；停住之后才看源窗口是不是真的看不见了，
    /// 移回后仍然没有新帧才提示（同一个 app 每次运行只提示一次）。
    private func checkChromiumCompatibility() {
        guard !isClosing, reconnector == nil, !showsHiddenPause, !showsMinimizedPause, !userPaused else { return }
        guard let bundleID = sourceBundleID, SourceAppCompatibility.isChromiumLike(bundleID: bundleID) else { return }
        let sinceLastFrame = capture.secondsSinceLastFrame
        guard ChromiumRenderHint.needsVisibilityCheck(secondsSinceLastFrame: sinceLastFrame) else {
            chromiumHint.reset()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let hint = chromiumHint.observe(visible: WindowLocator.isFullyVisible(source.id),
                                        arrivalAt: capture.lastArrivalTime, at: now)
        guard hint, SourceAppCompatibility.claimHint(bundleID: bundleID) else { return }
        let appName = source.ownerName
        // 本项目不自动重启 app：兼容模式只是把提示换成「怎么自己重启并带上后台渲染开关」
        Feedback.show(ChromiumCompatibilitySettings.shared.isEnabled
            ? String(localized: "“\(appName)” may stop redrawing while it's off screen. Quit it and reopen it with --disable-backgrounding-occluded-windows to keep the picture updating.")
            : String(localized: "“\(appName)” may stop redrawing while it's off screen. Turn on Chromium Compatibility Mode in Settings to see how to reopen it yourself with a background-rendering switch."))
    }

    /// 渲染卡顿第 3 级：重申配置和重建流都没让画面回来，告诉用户。
    private func rendererStalled() {
        guard !isClosing else { return }
        Feedback.show(String(localized: "The picture from “\(source.ownerName)” seems stuck. PipDog already tried restarting the capture; moving the source window or reopening the app may help."))
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
        updateControlBar()
    }

    /// 悬停隐藏中就恢复（再次 PiP 同一窗口时）
    func revealIfHidden() { hoverHider?.revealIfHidden() }

    // MARK: - 控制条

    /// 控制条上的暂停 / 继续：复用「原 app 隐藏」的暂停语义（保留最后一帧，恢复时重新开流）。
    /// 重连等待、原 app 隐藏、原窗口最小化期间不可用，这些状态的遮罩不受控制条影响。
    private func toggleUserPause() {
        guard !isClosing, reconnector == nil, !showsHiddenPause, !showsMinimizedPause else { return }
        if userPaused {
            resumeAfterUserPause()
        } else {
            userPaused = true
            updatePauseOverlay()
            capture.pauseUntilShown()
        }
    }

    /// 继续：重新开一条流（和取消隐藏同一套）。原 app 这时又隐藏了就等它回来，保持暂停。
    /// 只有真的恢复成功才清 `userPaused`：失败时保持暂停，按钮和画面才不会一个说暂停、一个在动。
    private func resumeAfterUserPause() {
        guard userPaused, capture.isPaused, !showsHiddenPause, !showsMinimizedPause else { return }
        Task {
            let resumed = await capture.resumeAfterUnhide()
            guard !isClosing else { return }
            guard resumed == true else { // false：没能恢复；nil：又隐藏了或另一次恢复正在进行
                if resumed == false { NSLog("PipDog: couldn't resume the paused PiP") }
                return
            }
            userPaused = false
            updatePauseOverlay()
            pauseAgainIfNeeded() // 恢复期间原 app 又隐藏 / 窗口最小化了：把流再停上
        }
    }

    /// 控制条的帧率按钮：按 CaptureSettings.frameRateOptions 循环到下一档。
    /// 能按 app 记就记在这个 app 上（设置里的「按 app 记录」会多一行），拿不到 bundle ID 才改全局默认。
    private func cycleFrameRate() {
        let options = CaptureSettings.frameRateOptions
        let next = options.firstIndex(of: frameRate).map { options[($0 + 1) % options.count] } ?? options[0]
        guard next != frameRate else { return }
        frameRate = next // 设置变化会再同步一次；这里先改，控制条马上显示新数字
        updateControlBar()
        if let bundleID = sourceBundleID {
            AppFrameRateSettings.shared.setFrameRate(next, forApp: bundleID)
        } else {
            CaptureSettings.shared.frameRate = next
        }
    }

    /// 控制条的自动隐藏开关：改的是全局设置（所有小窗一起变，设置里也同步）
    private func toggleHoverAutoHide() {
        PiPAppearanceSettings.shared.hoverAutoHide.toggle()
    }

    /// 把面板当前状态灌进控制条（唯一入口，控制条自己不猜状态）
    private func updateControlBar() {
        pipView?.controlBar.update(paused: userPaused,
                                   canPause: reconnector == nil && !showsHiddenPause && !showsMinimizedPause,
                                   frameRate: frameRate,
                                   hoverAutoHide: PiPAppearanceSettings.shared.hoverAutoHide)
    }

    /// 增强模式的悬停按键（指针已经确认停在这个小窗上）
    func handleHoverKey(_ key: EnhancedHotKeys.HoverKey) {
        guard !isClosing else { return }
        switch key {
        case .zoomIn: pipView?.zoom(by: 1.25)
        case .zoomOut: pipView?.zoom(by: 1 / 1.25)
        case .cycleFrameRate: cycleFrameRate()
        case .toggleStaticFrameRate: CaptureSettings.shared.reduceFrameRateWhenStatic.toggle()
        case .toggleHidden: hoverHider?.toggleManualHide()
        case .close: close()
        }
    }

    func start() async throws {
        orderFrontRegardless()
        hoverHider?.setEnabled(PiPAppearanceSettings.shared.hoverAutoHide)
        monitorTimer = Timer.scheduledOnCommonModes(interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSourceMinimized()
                self?.checkPiPVisibility()
                self?.checkChromiumCompatibility()
            }
        }
        frameRate = AppFrameRateSettings.shared.frameRate(forApp: sourceBundleID)
        updateControlBar()
        try await capture.start(fps: frameRate)
        // 启动期间（还没开始抓取）就按了暂停：现在真的能停了
        if userPaused, !isClosing { capture.pauseUntilShown() }
    }

    /// 设置里的帧率（全局默认或这个 app 的记录）或两个节能开关变了：立即应用到正在运行的抓取。
    func captureSettingsDidChange() {
        frameRate = AppFrameRateSettings.shared.frameRate(forApp: sourceBundleID)
        capture.setFrameRate(frameRate)
        capture.reapplyEfficiencySettings()
        updateControlBar()
    }

    /// 面板缩放结束（手柄、系统边缘缩放、跟随源宽高比）或换到像素比例不同的屏幕后调用：
    /// 抓取分辨率跟着面板的像素尺寸走，不按源窗口的原生分辨率抓。
    func contentSizeDidSettle() {
        guard !isClosing else { return }
        capture.setOutputLimit(pixelSize)
        invalidateShadow()
        onGeometryChanged?()
    }

    /// 拖动吸附时其他 PiP 要当参照：正在关闭、还没显示、悬停隐藏（看不见又点击穿透）的不算
    var isVisibleForSnapping: Bool { !isClosing && isVisible && alphaValue > 0.01 }

    /// 被悬停自动隐藏 / fn 轻点藏起来了：看不见、点击穿透
    var isHoverHidden: Bool { hoverHider?.isHidden ?? false }

    /// 抓取用的像素尺寸：面板像素尺寸（放大是采集端裁剪，面板不再按倍数放大）
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
        reconnector?.stop()
        reconnector = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        hoverHider?.stop()
        hoverHider = nil
        monitorTimer?.invalidate()
        monitorTimer = nil
        imageLayer.contents = nil
        currentFrame = nil
        super.close()
        onClose?()
        onClose = nil
        onReconnect = nil
        onEnded = nil
    }

    // MARK: - 单击

    /// 单击或双击（按设置，PiPContentView 已经判断过）切回原窗口（原窗口已在最前时移到屏幕边上）；
    /// ⌥ + 单击用快速查看看原尺寸截图。等待源 app 重启期间点一下立即查一次。
    private func clicked(modifiers: NSEvent.ModifierFlags) {
        guard !isClosing else { return }
        if reconnector != nil {
            reconnector?.checkNow()
            return
        }
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
                Feedback.show(String(localized: "Quick Look failed: \(WindowCapture.SnapshotError.busy.localizedDescription)")) // 上一次还在进行，前台由它负责
            } catch let error as WindowCapture.SnapshotError {
                SnapshotPreview.shared.restoreIfClosed()
                Feedback.show(String(localized: "Quick Look failed: \(error.localizedDescription)"))
            } catch let error as SnapshotPreview.WriteError {
                SnapshotPreview.shared.restoreIfClosed()
                Feedback.show(String(localized: "Quick Look failed: \(error.localizedDescription)"))
            } catch {
                SnapshotPreview.shared.restoreIfClosed()
                // ScreenCaptureKit 的原始错误（英文）不直接给用户看；明确是屏幕录制被拒才走权限引导
                NSLog("PipDog: Quick Look snapshot failed: \(error.localizedDescription)")
                if Permissions.isScreenRecordingError(error) {
                    Permissions.showAlert(.screenRecording, afterFailure: true)
                } else {
                    Feedback.show(String(localized: "Quick Look failed: the source window can't be captured right now. Try again later."))
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
        // 源 app 退出了：重连不是结束，小窗不关，等它重启（重连不上才走下面的关闭流程）
        let health = SourceWindowHealth.classify(appIsRunning: isSourceAppRunning,
                                                 windowIsListed: WindowLocator.bounds(of: source.id) != nil)
        if health == .appQuit, beginReconnect() { return }
        // 窗口还在、只是不在当前桌面（最小化、别的 Space）：系统停流是正常的，保持暂停等它回来，不要关小窗
        if health == .alive, showsMinimizedPause || WindowLocator.isOnScreen(source.id) == false {
            isWaitingForSourceReturn = true
            capture.pauseUntilShown()
            return
        }
        let ended = onEnded
        close()
        switch reason {
        case .windowClosed:
            ended?(String(localized: "The source window was closed, so the PiP ended"))
        case .failed(let error):
            // ScreenCaptureKit 的原始错误（英文）只写日志；屏幕录制被拒或运行中被撤销才走权限引导
            NSLog("PipDog: PiP capture stopped: \(error.localizedDescription)")
            if Permissions.isScreenRecordingLost(error) {
                Permissions.showAlert(.screenRecording, afterFailure: true)
            } else if WindowLocator.isOnScreen(source.id) == false {
                ended?(String(localized: "PiP ended: macOS stopped capturing because the source window isn't on the current desktop (it's minimized or on another desktop). Restore it and PiP it again."))
            } else {
                ended?(String(localized: "PiP ended: capture stopped unexpectedly. You can PiP this window again."))
            }
        }
    }

    // MARK: - 源 app 退出后重连

    /// 原 app 还在运行吗（进程已经没了就是退出了）
    private var isSourceAppRunning: Bool {
        guard let app = NSRunningApplication(processIdentifier: source.pid), !app.isTerminated else { return false }
        return true
    }

    /// 源 app 退出了：小窗不关，画面换成等待占位，按 bundleID 轮询等它重启（最多 5 分钟）。
    /// 返回 false 表示没法等（已经关掉，或拿不到 bundle ID），调用方照常关闭小窗；
    /// 已经在等的时候返回 true（退出通知和抓取结束可能都会走到这里）。
    @discardableResult
    private func beginReconnect() -> Bool {
        guard !isClosing, let bundleID = sourceBundleID else { return false }
        guard reconnector == nil else { return true }
        NSLog("PipDog: the source app quit; waiting for it to restart")
        showsHiddenPause = false
        showsMinimizedPause = false
        isWaitingForSourceReturn = false
        userPaused = false // 暂停是原来那条抓取的：重连后换成新的抓取，不继承
        chromiumHint.reset()
        let target = SourceWindowReconnector.Target(bundleID: bundleID, windowID: source.id,
                                                    title: sourceTitle, size: sourceWindowSize)
        let reconnector = SourceWindowReconnector(target: target)
        reconnector.onWindow = { [weak self] window in self?.reconnected(to: window) }
        reconnector.onTimeout = { [weak self] in self?.reconnectTimedOut() }
        self.reconnector = reconnector
        // 原来的抓取已经没用了（面板只保留最后一帧当背景），彻底停掉
        let old = capture
        Task { await old.stop() }
        updatePauseOverlay()
        reconnector.start()
        return true
    }

    /// 等太久了：照常关闭（走 onClose，恢复停放的窗口）
    private func reconnectTimedOut() {
        guard !isClosing else { return }
        reconnector = nil
        let ended = onEnded
        let appName = source.ownerName
        close()
        ended?(String(localized: "“\(appName)” didn't come back, so the PiP ended"))
    }

    /// 找到了重启后的窗口：用新 SCWindow 重建抓取，成功了才把面板换成新的源窗口身份。
    /// 失败就继续等下一个轮询周期（不关小窗、也不报错）。
    private func reconnected(to window: SCWindow) {
        guard !isClosing, !isStartingReconnectCapture else { return }
        // 区域 PiP：新窗口可能比原来小、位置也变了，把原区域裁进新窗口；完全落在窗口外就继续等
        var region: CGRect?
        if let sourceRegion {
            let clipped = sourceRegion.intersection(CGRect(origin: .zero, size: window.frame.size))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
                reconnector?.resumeWaiting()
                return
            }
            region = clipped
        }
        isStartingReconnectCapture = true
        let oldWindowID = source.id
        let previousBaseSize = capture.baseRect.size
        let newCapture = WindowCapture(window: window, region: region)
        wireCapture(newCapture)
        Task {
            defer { isStartingReconnectCapture = false }
            do {
                try await newCapture.start(fps: AppFrameRateSettings.shared.frameRate(forApp: sourceBundleID))
            } catch {
                NSLog("PipDog: couldn't start capture after the source app restarted: \(error.localizedDescription)")
                await newCapture.stop()
                guard !isClosing else { return } // 面板已经关了，reconnector 也一并丢掉：不要再让它继续等
                reconnector?.resumeWaiting() // 继续等下一次轮询，不关小窗也不报错
                return
            }
            guard !isClosing else {
                await newCapture.stop()
                return
            }
            // 启动期间源 app 可能又退出了：窗口不在了就继续等，不要把已经死掉的抓取换上来
            guard WindowLocator.bounds(of: window.windowID) != nil else {
                await newCapture.stop()
                reconnector?.resumeWaiting()
                return
            }
            let old = capture
            capture = newCapture
            newCapture.setOutputLimit(pixelSize) // 启动期间面板可能已经改过尺寸
            Task { await old.stop() }
            // 新窗口的基准矩形可能不一样：先按新窗口更新基准，再回到 1 倍
            sourceRegion = region // 位置记忆的 key 用裁剪后的区域
            (contentView as? PiPContentView)?.updateBaseRect(newCapture.baseRect)
            (contentView as? PiPContentView)?.resetZoom()
            if newCapture.baseRect.size != previousBaseSize {
                adaptAspect(to: newCapture.baseRect.size) // 整窗宽高比变了：面板尺寸跟着新窗口
            }
            let previous = source
            source = WindowInfo(id: window.windowID,
                                pid: window.owningApplication?.processID ?? previous.pid,
                                bounds: window.frame,
                                ownerName: window.owningApplication?.applicationName ?? previous.ownerName)
            sourceTitle = window.title
            sourceWindowSize = window.frame.size
            reconnector?.stop()
            reconnector = nil
            chromiumHint.reset()
            showsMinimizedPause = false
            isWaitingForSourceReturn = false
            updatePauseOverlay()
            onReconnect?(oldWindowID, window.windowID, source.pid)
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
