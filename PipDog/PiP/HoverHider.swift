import AppKit

/// 悬停自动隐藏（默认关闭）：鼠标在小窗上停留约 1.5 秒后，小窗淡出并让点击穿透到下面的窗口；
/// 鼠标离开小窗的范围，或单独按一下 ⌥（按下又松开，不超过 0.5 秒，期间没有点鼠标、没有按别的键或修饰键），就淡入恢复。
/// ⌥ + 点击下面的 app（终端移光标、浏览器下载链接等）照常穿透，不会让小窗恢复。
/// 进入用内容视图的跟踪区域和本 app 的鼠标事件发现；隐藏后小窗不接收鼠标，离开只看全局 / 本 app 的监听和
/// `NSEvent.mouseLocation`，不靠跟踪区域的 mouseExited（隐藏本身就会触发它，会来回闪）。隐藏期间另有 0.05 秒一次的
/// 检查（读 `NSEvent.modifierFlags` / `pressedMouseButtons`，不需要权限）：鼠标移到叠在一起的另一个小窗上
/// （本 app 的不是 key 的面板未必收到 mouseMoved），或没有权限收不到全局 flagsChanged 时也能恢复。
/// 「这次悬停不再隐藏，直到鼠标离开」（suppressed）的情况：在小窗上按下、滚动、捏合；按一下 ⌥ 或再次 PiP 同一窗口让它恢复；
/// 小窗出现时鼠标已经在它上面；按着鼠标经过（拖文件等）。按住 ⌥、指着 × 或缩放手柄时也先不隐藏。
/// 只改窗口的 alphaValue，不改保存的不透明度：恢复时用当时设置里的不透明度。
@MainActor
final class HoverHider {
    static let delay: TimeInterval = 1.5
    /// 隐藏 / 恢复后发出：ClickTrigger 据此重新读 PipDog 自己窗口的范围（穿透的小窗不算）
    static let clickThroughDidChange = Notification.Name("PipDog.PiPClickThroughDidChange")
    private static let fadeDuration: TimeInterval = 0.15
    private static let hiddenPollInterval: TimeInterval = 0.05
    /// 单独按一下 ⌥ 的最长时间
    private static let optionTapLimit: TimeInterval = 0.5

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
    /// 隐藏期间 ⌥ 按下的时间（nil：没按着）；按着期间点了鼠标、按了别的键或修饰键就作废（optionTapSpoiled）
    private var optionPressedAt: Date?
    private var optionTapSpoiled = false

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
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 鼠标在别的 app 上（包括隐藏后穿透下去的那个）。点击用来作废 ⌥ 单按（⌥ + 点击要穿透给下面的 app）；
        // 全局的 flagsChanged / keyDown 没有辅助功能权限时可能收不到，隐藏期间另有定时检查
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves.union(downs).union([.flagsChanged, .keyDown]),
                                                           handler: { [weak self] event in
            let spoils = event.type != .flagsChanged && !moves.contains(NSEvent.EventTypeMask(type: event.type))
            MainActor.assumeIsolated {
                guard let self else { return }
                if spoils { self.spoilOptionTap() }
                self.pointerMoved()
            }
        }) {
            monitors.append(monitor)
        }
        // PipDog 自己的窗口（这个小窗、别的小窗、设置窗口）
        let mask = moves.union(downs).union([.flagsChanged, .keyDown, .mouseEntered, .mouseExited, .scrollWheel, .magnify])
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let interacted = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify].contains(event.type)
            let spoils = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type)
            let window = event.window
            MainActor.assumeIsolated {
                guard let self else { return }
                if spoils { self.spoilOptionTap() }
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

    /// ⌥ 按着期间点了鼠标或按了别的键：这次不算单按。还没发现 ⌥ 按下（收不到全局 flagsChanged、定时检查还没轮到）
    /// 但现在按着时，也从这里开始记，并直接作废。
    private func spoilOptionTap() {
        guard optionPressedAt != nil || NSEvent.modifierFlags.contains(.option) else { return }
        if optionPressedAt == nil { optionPressedAt = Date() }
        optionTapSpoiled = true
    }

    /// 隐藏期间跟踪 ⌥ 的按下 → 松开；单独按一下（没作废、不超过 0.5 秒）返回 true。
    private func optionTapped() -> Bool {
        let flags = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift, .function])
        guard flags.contains(.option) else {
            defer { optionPressedAt = nil }
            guard let start = optionPressedAt else { return false }
            return !optionTapSpoiled && Date().timeIntervalSince(start) <= Self.optionTapLimit
        }
        // 和别的修饰键一起按、按着鼠标（定时检查兜底：全局 mouseDown 漏掉时）都作废
        let clean = flags == .option && NSEvent.pressedMouseButtons == 0 && !Self.nonModifierKeyDown()
        if optionPressedAt == nil {
            optionPressedAt = Date()
            optionTapSpoiled = !clean
        } else if !clean {
            optionTapSpoiled = true
        }
        return false
    }

    /// 有没有修饰键以外的键按着（⌥ + E 这类组合字符）。没有辅助功能时收不到全局 keyDown，
    /// 用 `CGEventSource.keyState` 直接读按键状态兜底。
    private static func nonModifierKeyDown() -> Bool {
        let modifierKeys: ClosedRange<CGKeyCode> = 54...63 // ⌘ ⇧ ⇪ ⌥ ⌃（左右）和 fn
        return (0..<128).contains { (code: CGKeyCode) in
            !modifierKeys.contains(code) && CGEventSource.keyState(.combinedSessionState, key: code)
        }
    }

    /// 鼠标移动、修饰键变化、定时检查都走这里。
    private func pointerMoved() {
        guard enabled else { return }
        let inside = pointerInside
        if isHidden {
            if !inside {
                reveal()
            } else if optionTapped() { // 隐藏时单独按一下 ⌥：马上回来，这次悬停不再隐藏
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
        timer = Timer.scheduledOnCommonModes(interval: Self.delay, repeats: false) { [weak self] _ in
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
        optionPressedAt = nil // 隐藏前就按着的 ⌥ 不算
        optionTapSpoiled = false
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
        hiddenPoll = Timer.scheduledOnCommonModes(interval: Self.hiddenPollInterval, repeats: true) { [weak self] _ in
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
