import AppKit

/// 悬停自动隐藏（默认关闭）：鼠标在小窗上停留约 1.5 秒后，小窗淡出并让点击穿透到下面的窗口；
/// 鼠标离开小窗的范围，或按下 ⌥，就淡入恢复。
/// 进入用内容视图的跟踪区域和本 app 的鼠标事件发现；隐藏后小窗不接收鼠标，离开只看全局 / 本 app 的监听和
/// `NSEvent.mouseLocation`，不靠跟踪区域的 mouseExited（隐藏本身就会触发它，会来回闪）。隐藏期间另有 0.1 秒一次的
/// 检查：鼠标移到叠在一起的另一个小窗上（本 app 的不是 key 的面板未必收到 mouseMoved），或没有权限收不到全局 ⌥ 时也能恢复。
/// 「这次悬停不再隐藏，直到鼠标离开」（suppressed）的情况：在小窗上按下、滚动、捏合；按 ⌥ 或再次 PiP 同一窗口让它恢复；
/// 小窗出现时鼠标已经在它上面；按着鼠标经过（拖文件等）。按住 ⌥、指着 × 或缩放手柄时也先不隐藏。
/// 只改窗口的 alphaValue，不改保存的不透明度：恢复时用当时设置里的不透明度。
@MainActor
final class HoverHider {
    static let delay: TimeInterval = 1.5
    /// 隐藏 / 恢复后发出：ClickTrigger 据此重新读 PipDog 自己窗口的范围（穿透的小窗不算）
    static let clickThroughDidChange = Notification.Name("PipDog.PiPClickThroughDidChange")
    private static let fadeDuration: TimeInterval = 0.15
    private static let hiddenPollInterval: TimeInterval = 0.1

    private weak var panel: NSPanel?
    /// 屏幕坐标的点是不是在 × 或缩放手柄上
    private let isOverChrome: (NSPoint) -> Bool
    private var monitors: [Any] = []
    private var timer: Timer?
    /// 隐藏期间的定时检查（鼠标离开、按下 ⌥）
    private var hiddenPoll: Timer?
    private var enabled = false
    private(set) var isHidden = false
    /// 这次悬停不再隐藏，直到鼠标离开小窗
    private var suppressed = false

    init(panel: NSPanel, isOverChrome: @escaping (NSPoint) -> Bool) {
        self.panel = panel
        self.isOverChrome = isOverChrome
    }

    /// 打开 / 关闭这个功能；关闭时立即恢复已隐藏的小窗。打开时鼠标已经在小窗上（例如新小窗出现在鼠标下面），
    /// 要等鼠标离开再进来才开始计时。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            installMonitors()
            suppressed = pointerInside
        } else {
            removeMonitors()
            cancelTimer()
            suppressed = false
            reveal()
        }
    }

    /// 小窗关闭：移除监听和计时器，不做动画。
    func stop() {
        enabled = false
        removeMonitors()
        cancelTimer()
        stopHiddenPoll()
    }

    /// 已隐藏就恢复（再次 PiP 同一个窗口时），并且这次悬停不再隐藏。
    func revealIfHidden() {
        guard isHidden else { return }
        reveal()
        suppressed = true
    }

    /// 跟踪区域报告鼠标进入（小窗不在前台时也有）
    func pointerEntered() { pointerMoved() }

    /// 跟踪区域报告鼠标离开；隐藏期间不理会（是隐藏本身引起的）
    func pointerExited() {
        guard !isHidden else { return }
        pointerMoved()
    }

    // MARK: - 内部

    private var pointerInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation) // 隐藏不改 frame；隐藏期间小窗改了大小也按新范围算
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // 鼠标在别的 app 上（包括隐藏后穿透下去的那个）。全局的 ⌥ 可能因为没有权限收不到，隐藏期间另有定时检查
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves.union(.flagsChanged), handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(monitor)
        }
        // PipDog 自己的窗口（这个小窗、别的小窗、设置窗口）
        let mask = moves.union([.flagsChanged, .mouseEntered, .mouseExited,
                                .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify])
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let interacted = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify].contains(event.type)
            let window = event.window
            MainActor.assumeIsolated {
                guard let self else { return }
                if interacted, let window, window === self.panel {
                    self.suppress()
                } else {
                    self.pointerMoved()
                }
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func suppress() {
        suppressed = true
        cancelTimer()
    }

    /// 鼠标移动、修饰键变化、定时检查都走这里。
    private func pointerMoved() {
        guard enabled else { return }
        let inside = pointerInside
        if isHidden {
            if !inside {
                reveal()
            } else if NSEvent.modifierFlags.contains(.option) { // 隐藏时按 ⌥：马上回来，这次悬停不再隐藏
                reveal()
                suppressed = true
            }
            return
        }
        guard inside else {
            cancelTimer()
            suppressed = false
            return
        }
        if NSEvent.pressedMouseButtons != 0 { // 按着鼠标经过（拖文件、框选）：松开后也要重新进来才计时
            suppress()
        } else if timer == nil, !suppressed {
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        cancelTimer()
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        timer = nil
        guard enabled, !isHidden, !suppressed, let panel, pointerInside else { return }
        if NSEvent.pressedMouseButtons != 0 { // 按着鼠标（拖动、缩放小窗、拖文件）：要重新进来
            suppress()
            return
        }
        // 按着 ⌥（准备快速查看）、正在缩放、鼠标在 × / 缩放手柄上：先不隐藏，过一会儿再看
        if NSEvent.modifierFlags.contains(.option) || panel.inLiveResize || isOverChrome(NSEvent.mouseLocation) {
            scheduleTimer()
            return
        }
        hide()
    }

    private func hide() {
        guard let panel else { return }
        isHidden = true
        panel.ignoresMouseEvents = true
        fade(panel, to: 0)
        startHiddenPoll()
        NotificationCenter.default.post(name: Self.clickThroughDidChange, object: panel)
    }

    private func reveal() {
        stopHiddenPoll()
        guard isHidden, let panel else { return }
        isHidden = false
        panel.ignoresMouseEvents = false
        fade(panel, to: PiPAppearanceSettings.shared.opacity) // 隐藏期间改过不透明度也用新的
        NotificationCenter.default.post(name: Self.clickThroughDidChange, object: panel)
    }

    private func startHiddenPoll() {
        stopHiddenPoll()
        hiddenPoll = Timer.scheduledTimer(withTimeInterval: Self.hiddenPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    private func stopHiddenPoll() {
        hiddenPoll?.invalidate()
        hiddenPoll = nil
    }

    private func fade(_ panel: NSPanel, to alpha: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        }
    }
}
