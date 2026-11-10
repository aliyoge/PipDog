import AppKit

/// 悬停自动隐藏：鼠标在小窗上停留约 0.6 秒后，小窗淡出并让点击穿透到下面的窗口；鼠标离开小窗原来的范围后淡入恢复。
/// 进入用内容视图的跟踪区域和本 app 的鼠标移动发现；隐藏后小窗不接收鼠标，离开只看全局 / 本 app 的鼠标移动监听和
/// `NSEvent.mouseLocation`，不靠跟踪区域的 mouseExited（隐藏本身就会触发它，会来回闪）。
/// 在小窗上按下鼠标、滚动或捏合后，这次悬停不再隐藏，直到鼠标离开；按着鼠标或 ⌥、鼠标在 × 或缩放手柄上时也先不隐藏。
/// 只改窗口的 alphaValue，不改保存的不透明度：恢复时用当时设置里的不透明度。
@MainActor
final class HoverHider {
    static let delay: TimeInterval = 0.6
    /// 隐藏 / 恢复后发出：ClickTrigger 据此重新读 PipDog 自己窗口的范围（穿透的小窗不算）
    static let clickThroughDidChange = Notification.Name("PipDog.PiPClickThroughDidChange")
    private static let fadeDuration: TimeInterval = 0.15

    private weak var panel: NSPanel?
    /// 屏幕坐标的点是不是在 × 或缩放手柄上
    private let isOverChrome: (NSPoint) -> Bool
    private var monitors: [Any] = []
    private var timer: Timer?
    private var enabled = false
    private(set) var isHidden = false
    /// 隐藏前的小窗范围：鼠标离开它才恢复
    private var hiddenFrame = NSRect.zero
    /// 这次悬停里用户已经在小窗上操作过（按下、滚动、捏合）：不再隐藏，直到鼠标离开
    private var suppressed = false

    init(panel: NSPanel, isOverChrome: @escaping (NSPoint) -> Bool) {
        self.panel = panel
        self.isOverChrome = isOverChrome
    }

    /// 打开 / 关闭这个功能；关闭时立即恢复已隐藏的小窗。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            installMonitors()
            pointerMoved()
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
    }

    /// 跟踪区域报告鼠标进入（小窗不在前台时也有）
    func pointerEntered() { pointerMoved() }

    /// 跟踪区域报告鼠标离开；隐藏期间不理会（是隐藏本身引起的）
    func pointerExited() {
        guard !isHidden else { return }
        pointerMoved()
    }

    // MARK: - 内部

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // 鼠标在别的 app 上（包括隐藏后穿透下去的那个）
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(monitor)
        }
        // 鼠标在 PipDog 自己的窗口上（这个小窗、别的小窗、设置窗口）
        let interactions: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves.union(interactions), handler: { [weak self] event in
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

    private func pointerMoved() {
        guard enabled, let panel else { return }
        let mouse = NSEvent.mouseLocation
        if isHidden {
            if !hiddenFrame.contains(mouse) { reveal() }
            return
        }
        if panel.isVisible, panel.frame.contains(mouse) {
            if timer == nil, !suppressed { scheduleTimer() }
        } else {
            cancelTimer()
            suppressed = false
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
        guard enabled, !isHidden, !suppressed, let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else { return }
        // 按着鼠标（拖动、缩放小窗）、按着 ⌥（准备快速查看）、鼠标在 × / 缩放手柄上：先不隐藏，过一会儿再看
        if NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.option) || panel.inLiveResize
            || isOverChrome(mouse) {
            scheduleTimer()
            return
        }
        hide()
    }

    private func hide() {
        guard let panel else { return }
        isHidden = true
        hiddenFrame = panel.frame
        panel.ignoresMouseEvents = true
        fade(panel, to: 0)
        NotificationCenter.default.post(name: Self.clickThroughDidChange, object: panel)
    }

    private func reveal() {
        guard isHidden, let panel else { return }
        isHidden = false
        panel.ignoresMouseEvents = false
        fade(panel, to: PiPAppearanceSettings.shared.opacity) // 隐藏期间改过不透明度也用新的
        NotificationCenter.default.post(name: Self.clickThroughDidChange, object: panel)
    }

    private func fade(_ panel: NSPanel, to alpha: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        }
    }
}
