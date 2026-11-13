import AppKit

/// PiP 顶部的悬停控制条：半透明胶囊 + 一排小图标按钮（暂停 / 帧率 / 重置缩放 / 自动隐藏 / 关闭）。
///
/// - 只有落在按钮上的点击由本视图接收；空白区域的 `hitTest` 返回 nil，事件落到内容视图，
///   于是按住控制条空白处照样能拖动面板，点一下也不算「切回源窗口」的点击（由内容视图判断）。
/// - 指针在按钮上时高亮，并立刻在下方显示名称：不用系统 tooltip——面板是浮动层，tooltip 会被压住，
///   而且系统 tooltip 有初始延迟。
/// - 淡入淡出 0.12 秒，淡出结束后 `isHidden = true`，不再参与命中测试。
/// - 控制条是内容视图的子视图，和 ×、倍数提示一样不随缩放变化。
final class PiPControlBar: NSView {
    /// 控制条高度（PiPContentView 摆放时用）
    static let height: CGFloat = 30

    // MARK: - 回调

    var onTogglePause: (() -> Void)?
    var onCycleFrameRate: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onToggleHoverAutoHide: (() -> Void)?
    var onClose: (() -> Void)?

    // MARK: - 尺寸与颜色

    private enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let button: CGFloat = 22
        static let gap: CGFloat = 2
        static let trailingInset: CGFloat = 4
        static let symbolPointSize: CGFloat = 11
        static let fade: TimeInterval = 0.12
        /// 悬停高亮块比按钮各边外扩的距离
        static let hoverPadding: CGFloat = 1
        static let hoverCornerRadius: CGFloat = 5
        static let hintGap: CGFloat = 6
        static let hintInset: CGFloat = 4
    }

    /// 悬停高亮块底色
    private static var hoverFill: NSColor { NSColor.white.withAlphaComponent(0.18) }
    /// 常态图标色（HUD 底固定是深色，用白色系，不跟随系统浅色外观）
    private static var inactiveTint: NSColor { NSColor.white.withAlphaComponent(0.85) }
    /// 开关处于「开」时
    private static var activeTint: NSColor { .controlAccentColor }
    /// 不可用
    private static var disabledTint: NSColor { NSColor.white.withAlphaComponent(0.3) }

    private enum TintRole {
        case active, inactive, disabled
    }

    // MARK: - 子视图

    private let backdrop = NSVisualEffectView()
    /// 按钮和背板的裁切容器：面板很窄时按钮只在本条范围内显示，不会画到左上角的 × 上
    private let buttonClip = NSView()
    /// 复用的悬停高亮块：始终只有一层，跟着当前悬停的按钮走
    private let hoverHighlight = NSView()
    private let hint = ControlBarHint()

    private let pauseButton = ControlBarButton()
    private let frameRateButton = ControlBarButton()
    private let resetZoomButton = ControlBarButton()
    private let autoHideButton = ControlBarButton()
    private let closeButton = ControlBarButton()

    /// 视觉上从左到右：暂停 / 帧率 / 重置缩放 / 自动隐藏 / 关闭
    private var buttons: [ControlBarButton] { [pauseButton, frameRateButton, resetZoomButton, autoHideButton, closeButton] }
    /// 从右往左摆放的顺序
    private var buttonsRightToLeft: [ControlBarButton] { buttons.reversed() }

    /// `setVisible` 的目标态：淡出回调不能把刚重新显示的控制条又藏起来
    private var desiredVisible = false
    /// 当前悬停的按钮（禁用按钮不参与）
    private weak var hoveredButton: ControlBarButton?
    private var hintTexts: [ObjectIdentifier: String] = [:]
    private var tintRoles: [ObjectIdentifier: TintRole] = [:]
    /// 帧率按钮上显示的数字（「15 fps」是数字加单位，不翻译）
    private var frameRate = CaptureSettings.defaultFrameRate

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // HUD 材质本身就是深色：固定暗色外观，浅色系统下白色图标同样清楚
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = 0
        isHidden = true

        buttonClip.frame = bounds
        buttonClip.autoresizingMask = [.width, .height]
        buttonClip.clipsToBounds = true
        addSubview(buttonClip)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = buttonClip.bounds
        buttonClip.addSubview(backdrop)

        hoverHighlight.wantsLayer = true
        hoverHighlight.layer?.cornerRadius = Metrics.hoverCornerRadius
        hoverHighlight.layer?.backgroundColor = Self.hoverFill.cgColor
        hoverHighlight.isHidden = true
        buttonClip.addSubview(hoverHighlight) // 按钮在它上面（configureButtons 里按顺序加）

        hint.isHidden = true
        addSubview(hint)

        configureButtons()
        refreshTints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureButtons() {
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.image = Self.symbol("pause.fill", label: String(localized: "Pause"))
        pauseButton.setAccessibilityLabel(String(localized: "Pause"))

        frameRateButton.target = self
        frameRateButton.action = #selector(frameRateClicked)
        frameRateButton.imagePosition = .noImage // 只有文字（「15 fps」）
        frameRateButton.setAccessibilityLabel(String(localized: "Frame Rate"))

        resetZoomButton.target = self
        resetZoomButton.action = #selector(resetZoomClicked)
        resetZoomButton.image = Self.symbol("arrow.counterclockwise", label: String(localized: "Reset zoom"))
        resetZoomButton.setAccessibilityLabel(String(localized: "Reset zoom"))
        setHint(String(localized: "Reset zoom"), for: resetZoomButton)

        autoHideButton.target = self
        autoHideButton.action = #selector(autoHideClicked)
        autoHideButton.image = Self.symbol("eye.slash", label: String(localized: "Hide on Hover"))
        autoHideButton.setAccessibilityLabel(String(localized: "Hide on Hover"))

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.image = Self.symbol("xmark", label: String(localized: "Close"))
        closeButton.setAccessibilityLabel(String(localized: "Close"))
        setHint(String(localized: "Close"), for: closeButton)

        for (index, button) in buttons.enumerated() {
            // 悬停检测挂在按钮自己身上（owner 是本视图）：控制条空白处的 hitTest 返回 nil，
            // 靠跟踪区域照样能收到进入 / 离开
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: ["index": index]))
            buttonClip.addSubview(button) // 和背板、高亮同一坐标系，超出条外会被裁掉
        }
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        buttonClip.frame = bounds
        backdrop.frame = buttonClip.bounds
        var rightEdge = max(bounds.width - Metrics.trailingInset, 0)
        let naturalWidth = buttons.reduce(CGFloat.zero) { $0 + buttonWidth($1) }
            + Metrics.gap * CGFloat(buttons.count - 1)
        // 面板很窄时按比例缩小按钮和间距，让按钮全部收在控制条里（多出来的部分还会被 buttonClip 裁掉）
        let scale = naturalWidth > rightEdge && naturalWidth > 0 ? rightEdge / naturalWidth : 1
        let gap = Metrics.gap * scale
        for button in buttonsRightToLeft {
            let width = buttonWidth(button) * scale
            button.frame = NSRect(x: rightEdge - width, y: (bounds.height - Metrics.button) / 2,
                                  width: width, height: Metrics.button)
            rightEdge = button.frame.minX - gap
        }
        if let hoveredButton {
            moveHighlight(to: hoveredButton.frame)
            layoutHint(for: hoveredButton)
        }
    }

    private func buttonWidth(_ button: ControlBarButton) -> CGFloat {
        button === frameRateButton ? frameRateButtonWidth : Metrics.button
    }

    /// 帧率按钮按「15 fps」的文字宽度撑开，数字用等宽字体，切换时不会左右抖
    private var frameRateButtonWidth: CGFloat {
        let textWidth = frameRateButton.attributedTitle.size().width
        return max(Metrics.button, ceil(textWidth) + 12)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true // 面板缩放后按钮要重新排（控制条自己不会因为这个 frame 变化自动 layout）
    }

    // MARK: - 状态刷新

    /// 面板状态灌进来：暂停 / 继续、能不能暂停、帧率、悬停自动隐藏开关。
    func update(paused: Bool, canPause: Bool, frameRate: Int, hoverAutoHide: Bool) {
        self.frameRate = frameRate

        let pauseName = paused ? String(localized: "Resume") : String(localized: "Pause")
        pauseButton.image = Self.symbol(paused ? "play.fill" : "pause.fill", label: pauseName)
        pauseButton.setAccessibilityLabel(pauseName)
        pauseButton.isEnabled = canPause
        setHint(pauseName, for: pauseButton)

        autoHideButton.image = Self.symbol(hoverAutoHide ? "eye.slash" : "eye", label: String(localized: "Hide on Hover"))
        autoHideButton.setAccessibilityLabel(String(localized: "Hide on Hover"))
        setHint(hoverAutoHide ? String(localized: "Hide on Hover is on")
                             : String(localized: "Hide on Hover is off"), for: autoHideButton)
        setHint(String(localized: "Click to switch frame rate"), for: frameRateButton)

        tintRoles[ObjectIdentifier(pauseButton)] = paused ? .active : .inactive
        tintRoles[ObjectIdentifier(autoHideButton)] = hoverAutoHide ? .active : .inactive
        tintRoles[ObjectIdentifier(frameRateButton)] = .inactive
        tintRoles[ObjectIdentifier(resetZoomButton)] = .inactive
        tintRoles[ObjectIdentifier(closeButton)] = .inactive

        refreshTints()
        // 悬停中的按钮被禁用（例如源窗口最小化让暂停不可用）：高亮和名称提示一起收掉
        if let hoveredButton, !hoveredButton.isEnabled { hover(nil) }
        needsLayout = true // 帧率按钮宽度可能变了
        if let hoveredButton { // 状态变了：名称提示的内容也跟着换
            layoutHint(for: hoveredButton)
            showHint(for: hoveredButton)
        }
    }

    private func setHint(_ text: String, for button: NSButton) {
        hintTexts[ObjectIdentifier(button)] = text
    }

    private func refreshTints() {
        for button in buttons {
            let role = button.isEnabled ? (tintRoles[ObjectIdentifier(button)] ?? .inactive) : .disabled
            let color = Self.tintColor(role, hovered: hoveredButton === button && button.isEnabled)
            if button === frameRateButton {
                frameRateButton.attributedTitle = NSAttributedString(string: "\(frameRate) fps", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: color,
                ])
            } else {
                button.contentTintColor = color
            }
        }
    }

    private static func tintColor(_ role: TintRole, hovered: Bool) -> NSColor {
        switch role {
        case .active: return hovered ? (activeTint.highlight(withLevel: 0.3) ?? activeTint) : activeTint
        case .inactive: return hovered ? .white : inactiveTint
        case .disabled: return disabledTint
        }
    }

    // MARK: - 显示 / 隐藏

    /// 淡入淡出；淡出结束后 `isHidden = true`，不再参与命中测试。
    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        if visible { isHidden = false } else { hover(nil) }
        guard animated else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, !self.desiredVisible else { return }
                self.isHidden = true
            }
        })
    }

    /// 点（内容视图坐标）是不是落在控制条或它的名称提示上：HoverHider 据此把控制条算作
    /// 「正在交互的 chrome」（不淡出），内容视图据此区分点控制条和点画面。
    func contains(contentPoint: NSPoint) -> Bool {
        guard !isHidden, alphaValue > 0.05 else { return false }
        if frame.contains(contentPoint) { return true }
        guard !hint.isHidden else { return false }
        return hint.frame.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -2, dy: -2).contains(contentPoint)
    }

    // MARK: - 悬停高亮与名称提示

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["index"] as? Int, buttons.indices.contains(index) else { return }
        hover(buttons[index])
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["index"] != nil else { return }
        // 相邻按钮之间移动时 enter / exit 的先后不保证：按鼠标当前位置再确认一次
        guard let window else { return hover(nil) }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if let index = buttons.firstIndex(where: { $0.isEnabled && $0.frame.insetBy(dx: -2, dy: -2).contains(local) }) {
            hover(buttons[index])
        } else {
            hover(nil)
        }
    }

    private func hover(_ button: ControlBarButton?) {
        let target = button?.isEnabled == true ? button : nil
        guard target !== hoveredButton else { return }
        hoveredButton = target
        refreshTints()
        guard let target else {
            hoverHighlight.isHidden = true
            hint.isHidden = true
            return
        }
        moveHighlight(to: target.frame)
        hoverHighlight.isHidden = false
        hint.isHidden = false
        layoutHint(for: target)
        showHint(for: target)
    }

    private func showHint(for button: NSButton) {
        let active = tintRoles[ObjectIdentifier(button)] == .active
        hint.show(hintTexts[ObjectIdentifier(button)] ?? "", color: active ? Self.activeTint : .white)
    }

    private func moveHighlight(to buttonFrame: NSRect) {
        hoverHighlight.frame = buttonFrame.insetBy(dx: -Metrics.hoverPadding, dy: -Metrics.hoverPadding)
    }

    /// 名称提示摆在按钮正下方（控制条边缘那一侧），左右收在控制条范围内
    private func layoutHint(for button: NSButton) {
        let size = hint.size(fitting: hintTexts[ObjectIdentifier(button)] ?? "")
        let center = button.frame.midX
        let x = min(max(center - size.width / 2, Metrics.hintInset), bounds.width - size.width - Metrics.hintInset)
        hint.frame = NSRect(x: x.rounded(), y: -size.height - Metrics.hintGap, width: size.width, height: size.height)
    }

    // MARK: - 命中测试（保住面板拖动和画面上的手势）

    /// 只有可见且可用的按钮接收点击；空白区域返回 nil，事件落到内容视图。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in buttons where button.isEnabled && !button.isHidden {
            if button.frame.insetBy(dx: -2, dy: -2).contains(local) { return button }
        }
        return nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 按钮动作

    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func frameRateClicked() { onCycleFrameRate?() }
    @objc private func resetZoomClicked() { onResetZoom?() }
    @objc private func autoHideClicked() { onToggleHoverAutoHide?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: - SF Symbols

    private static func symbol(_ name: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.symbolPointSize, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
    }
}

/// 控制条上的图标按钮：面板几乎不会成为 key window，第一次点击也要生效。
private final class ControlBarButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 按钮名称提示：深色小圆角块，画在控制条下方，不接收鼠标。
private final class ControlBarHint: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 提示块的尺寸（同时把文字设进去，`show` 之后 label 的宽度就对）
    func size(fitting text: String) -> NSSize {
        label.stringValue = text
        let textSize = label.sizeThatFits(NSSize(width: 260, height: 20))
        return NSSize(width: ceil(textSize.width) + 12, height: 18)
    }

    func show(_ text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        label.frame = NSRect(x: 6, y: 2, width: max(bounds.width - 12, 1), height: max(bounds.height - 4, 1))
    }
}