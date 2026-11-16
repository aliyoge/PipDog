import AppKit

/// PiP 右上角的悬停控制条：HUD 材质胶囊 + 一排小图标按钮（暂停 / 帧率 / 重置缩放 / 自动隐藏）。
///
/// - 只有落在按钮上的点击由本视图接收；空白区域的 `hitTest` 返回 nil，事件落到内容视图，
///   于是按住控制条空白处照样能拖动面板，点一下也不算「切回源窗口」的点击（由内容视图判断）。
/// - 指针在按钮上时高亮，并立刻在下方显示名称：不用系统 tooltip——面板是浮动层，tooltip 会被压住，
///   而且系统 tooltip 有初始延迟。
/// - 背板只包住按钮（宽度跟着内容收成胶囊），不再横跨窗口顶部；圆角永远是高度的一半。
/// - 淡入 0.14 秒（透明度 + 2pt 下落）、淡出 0.10 秒，淡出结束后 `isHidden = true`，不再参与命中测试。
/// - 控制条是内容视图的子视图，和 ×、倍数提示一样不随缩放变化；面板变窄时按三档降级，按钮始终保持正方形。
final class PiPControlBar: NSView {
    /// 控制条在常规档（面板 ≥ 210pt）的高度：最窄一档按 85% 缩成 24，`Tier.height` 照着它算
    nonisolated static let height: CGFloat = 28

    // MARK: - 回调

    var onTogglePause: (() -> Void)?
    var onCycleFrameRate: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onToggleHoverAutoHide: (() -> Void)?

    // MARK: - 尺寸与颜色

    private enum Metrics {
        /// 胶囊两端的左右边距
        static let sidePadding: CGFloat = 4
        static let button: CGFloat = 22
        static let gap: CGFloat = 3
        /// 中等宽度面板把按钮间距压到 1.5pt（按钮仍是 22×22 正方形）
        static let compactGap: CGFloat = 1.5
        /// 帧率按钮文字两侧的留白
        static let frameRateTextPadding: CGFloat = 12
        /// 悬停 / 按下 / 激活底块：和按钮一样大，不外扩，圆角 6pt
        static let fillCornerRadius: CGFloat = 6
        static let symbolPointSize: CGFloat = 11.5
        static let fadeIn: TimeInterval = 0.14
        static let fadeOut: TimeInterval = 0.10
        /// 淡入时从上方 2pt 落到最终位置
        static let enterOffset: CGFloat = 2
        /// 名称提示和按钮下边缘的距离
        static let hintGap: CGFloat = 5
        /// 名称提示左右收在控制条范围内的最小留白
        static let hintSideInset: CGFloat = 4
        /// 名称提示文字的最大宽度（超出按尾部截断）
        static let hintMaximumTextWidth: CGFloat = 260
        /// 面板宽于 210pt 全展开，160…210pt 只压间距，窄于 160pt 整体缩到 85%
        static let fullPanelWidth: CGFloat = 210
        static let compactPanelWidth: CGFloat = 160
        static let tinyScale: CGFloat = 0.85
    }

    /// 面板宽度的三档降级：只改尺寸，按钮永远保持正方形，不会被压成竖条。
    private enum Tier {
        case full
        case compact
        case tiny

        init(panelWidth: CGFloat) {
            if panelWidth < Metrics.compactPanelWidth {
                self = .tiny
            } else if panelWidth < Metrics.fullPanelWidth {
                self = .compact
            } else {
                self = .full
            }
        }

        /// 只有最窄一档整体缩放
        var scale: CGFloat { self == .tiny ? Metrics.tinyScale : 1 }
        var height: CGFloat { (PiPControlBar.height * scale).rounded() }
        var button: CGFloat { (Metrics.button * scale).rounded() }
        /// 完整胶囊：圆角永远是高度的一半
        var cornerRadius: CGFloat { height / 2 }
        var fillCornerRadius: CGFloat { (Metrics.fillCornerRadius * scale).rounded() }
        /// 最窄一档连间距一起缩：3 × 0.85 ≈ 2.5
        var gap: CGFloat { self == .compact ? Metrics.compactGap : Metrics.gap * scale }
        var sidePadding: CGFloat { (Metrics.sidePadding * scale).rounded() }
        var frameRateTextPadding: CGFloat {
            (self == .compact ? Metrics.frameRateTextPadding - 2 : Metrics.frameRateTextPadding) * scale
        }
    }

    /// 悬停底块：HUD 底上的一层轻白
    private static var hoverFill: NSColor { NSColor.white.withAlphaComponent(0.14) }
    /// 按下底块：比悬停再深一层
    private static var pressedFill: NSColor { NSColor.white.withAlphaComponent(0.24) }
    /// 激活态（暂停中 / 悬停自动隐藏打开）：深色 HUD 上只把图标染成系统蓝对比度太低，垫一层浅色 accent
    private static var activeFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.28) }
    /// 常态图标色（HUD 底固定是深色，用白色系，不跟随系统浅色外观）
    private static var inactiveTint: NSColor { NSColor.white.withAlphaComponent(0.85) }
    /// 开关处于「开」时：提亮到纯白，压在 accent 底块上
    private static var activeTint: NSColor { .white }
    /// 不可用
    private static var disabledTint: NSColor { NSColor.white.withAlphaComponent(0.28) }
    /// 胶囊的细描边
    private static var borderColor: NSColor { NSColor.white.withAlphaComponent(0.12) }

    private enum TintRole {
        case active, inactive, disabled
    }

    // MARK: - 子视图

    private let backdrop = NSVisualEffectView()
    /// 按钮和背板的裁切容器：面板很窄时按钮只在本条范围内显示，不会画到左上角的 × 上
    private let buttonClip = NSView()
    private let hint = ControlBarHint()

    private let pauseButton = ControlBarButton()
    private let frameRateButton = ControlBarButton()
    private let resetZoomButton = ControlBarButton()
    private let autoHideButton = ControlBarButton()

    /// 视觉上从左到右：暂停 / 帧率 / 重置缩放 / 自动隐藏（关闭在左上角，控制条里不再重复）
    private var buttons: [ControlBarButton] { [pauseButton, frameRateButton, resetZoomButton, autoHideButton] }
    /// 从右往左摆放的顺序
    private var buttonsRightToLeft: [ControlBarButton] { buttons.reversed() }

    /// 面板宽度决定的三档尺寸（由 `size(fittingPanelWidth:)` 定，`layout` 照着排按钮）
    private var tier = Tier.full
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
        // 投影挂在控制条自己的图层上：背板要 masksToBounds 裁毛玻璃，会把自己的投影一起裁掉；
        // 这一层没有不透明内容，靠 layout 里的 shadowPath 投出胶囊的影子
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.shadowRadius = 6

        buttonClip.frame = bounds
        buttonClip.autoresizingMask = [.width, .height]
        buttonClip.clipsToBounds = true
        addSubview(buttonClip)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5 // 细描边，深浅画面上轮廓都清楚
        backdrop.layer?.borderColor = Self.borderColor.cgColor
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = buttonClip.bounds
        buttonClip.addSubview(backdrop)

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

        for (index, button) in buttons.enumerated() {
            button.onPressedChanged = { [weak self] in self?.refreshTints() }
            // 悬停检测挂在按钮自己身上（owner 是本视图）：控制条空白处的 hitTest 返回 nil，
            // 靠跟踪区域照样能收到进入 / 离开
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: ["index": index]))
            buttonClip.addSubview(button) // 和背板同一坐标系，超出条外会被裁掉
        }
    }

    // MARK: - 布局

    /// 面板宽度对应的控制条尺寸（PiPContentView 摆放时用）：宽度跟着按钮收成胶囊，最窄一档整体缩到 85%
    func size(fittingPanelWidth panelWidth: CGFloat) -> NSSize {
        let newTier = Tier(panelWidth: panelWidth)
        if newTier != tier {
            tier = newTier
            needsLayout = true
        }
        return NSSize(width: naturalWidth, height: tier.height)
    }

    override func layout() {
        super.layout()
        buttonClip.frame = bounds
        backdrop.frame = buttonClip.bounds
        backdrop.layer?.cornerRadius = tier.cornerRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: tier.cornerRadius,
                                   cornerHeight: tier.cornerRadius, transform: nil)
        // 放得下就右对齐（胶囊贴住右上角）；frame 比内容还窄时改成从左往右排：
        // 暂停、帧率优先保住，溢出的是自动隐藏、恢复原大小，落在条外由 buttonClip 裁掉，不会压到左上角的 ×
        let fits = bounds.width >= naturalWidth
        let y = ((bounds.height - tier.button) / 2).rounded()
        var edge = fits ? max(bounds.width - tier.sidePadding, 0) : tier.sidePadding
        for button in (fits ? buttonsRightToLeft : buttons) {
            let width = buttonWidth(button)
            button.frame = NSRect(x: fits ? edge - width : edge, y: y, width: width, height: tier.button)
            button.layer?.cornerRadius = tier.fillCornerRadius
            edge = fits ? button.frame.minX - tier.gap : button.frame.maxX + tier.gap
        }
        if let hoveredButton, !hint.isHidden { hint.frame = hintFrame(for: hoveredButton) }
    }

    /// 胶囊按内容自然收拢的宽度
    private var naturalWidth: CGFloat {
        let buttonsWidth = buttons.reduce(CGFloat.zero) { $0 + buttonWidth($1) }
        return tier.sidePadding * 2 + buttonsWidth + tier.gap * CGFloat(buttons.count - 1)
    }

    private func buttonWidth(_ button: ControlBarButton) -> CGFloat {
        button === frameRateButton ? frameRateButtonWidth : tier.button
    }

    /// 帧率按钮按「15 fps」的文字宽度撑开，数字用等宽字体，切换时不会左右抖
    private var frameRateButtonWidth: CGFloat {
        let textWidth = frameRateButton.attributedTitle.size().width
        return max(tier.button, ceil(textWidth) + tier.frameRateTextPadding)
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

        refreshTints()
        // 悬停中的按钮被禁用（例如源窗口最小化让暂停不可用）：高亮和名称提示一起收掉
        if let hoveredButton, !hoveredButton.isEnabled { hover(nil) }
        needsLayout = true // 帧率按钮宽度可能变了
        // 胶囊宽度跟着帧率文字走（「5 fps」→「10 fps」会变宽）：让父视图重新量一遍并重摆
        superview?.needsLayout = true
        if let hoveredButton { // 状态变了：名称提示的内容也跟着换
            hint.show(hintTexts[ObjectIdentifier(hoveredButton)] ?? "", at: hintFrame(for: hoveredButton))
        }
    }

    private func setHint(_ text: String, for button: NSButton) {
        hintTexts[ObjectIdentifier(button)] = text
    }

    private func refreshTints() {
        for button in buttons {
            let role = button.isEnabled ? (tintRoles[ObjectIdentifier(button)] ?? .inactive) : .disabled
            let hovered = hoveredButton === button && button.isEnabled
            let pressed = hovered && button.isPressed
            let color = Self.tintColor(role, hovered: hovered, pressed: pressed)
            button.fillColor = Self.fillColor(role, hovered: hovered, pressed: pressed)
            if button === frameRateButton {
                frameRateButton.attributedTitle = NSAttributedString(string: "\(frameRate) fps", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: color,
                ])
            } else {
                button.contentTintColor = color
            }
        }
    }

    private static func tintColor(_ role: TintRole, hovered: Bool, pressed: Bool) -> NSColor {
        switch role {
        case .active: return activeTint
        case .inactive: return pressed ? NSColor.white.withAlphaComponent(0.9) : (hovered ? .white : inactiveTint)
        case .disabled: return disabledTint
        }
    }

    private static func fillColor(_ role: TintRole, hovered: Bool, pressed: Bool) -> NSColor {
        if pressed { return pressedFill }
        switch role {
        case .active: return activeFill
        case .inactive: return hovered ? hoverFill : .clear
        case .disabled: return .clear
        }
    }

    // MARK: - 显示 / 隐藏

    /// 淡入 0.14 秒（带 2pt 下落）、淡出 0.10 秒；淡出结束后 `isHidden = true`，不再参与命中测试。
    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        // 已经可见时再显示（进入 + HoverHider 恢复各调一次）不重播下落
        let wasHidden = isHidden || alphaValue <= 0.01
        if visible { isHidden = false } else { hover(nil) }
        guard animated else {
            layer?.removeAnimation(forKey: "appear")
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }
        if !visible {
            layer?.removeAnimation(forKey: "appear") // 淡出不该叠着还没跑完的下落
        } else if wasHidden {
            // 从上方 2pt 落到最终位置：只动渲染，不动 frame（命中判断用的还是最终位置）
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = Metrics.enterOffset
            slide.toValue = 0
            slide.duration = Metrics.fadeIn
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(slide, forKey: "appear")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? Metrics.fadeIn : Metrics.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
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
        if let index = buttons.firstIndex(where: { $0.isEnabled && $0.frame.insetBy(dx: -hitOutset, dy: -hitOutset).contains(local) }) {
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
            hint.hide()
            return
        }
        hint.show(hintTexts[ObjectIdentifier(target)] ?? "", at: hintFrame(for: target))
    }

    /// 名称提示摆在按钮正下方（控制条边缘那一侧），左右收在控制条范围内；
    /// 提示比胶囊还宽时贴到条的左边缘（x = 0），不再出现负的 x 伸到左上角的 × 上
    private func hintFrame(for button: NSButton) -> NSRect {
        let size = hint.size(fitting: hintTexts[ObjectIdentifier(button)] ?? "")
        let center = button.frame.midX
        let maxX = bounds.width - size.width - Metrics.hintSideInset
        let x = maxX < Metrics.hintSideInset
            ? 0
            : min(max(center - size.width / 2, Metrics.hintSideInset), maxX)
        return NSRect(x: x.rounded(), y: -size.height - Metrics.hintGap, width: size.width, height: size.height)
    }

    // MARK: - 命中测试（保住面板拖动和画面上的手势）

    /// 按钮热区的外扩量：不超过间距的一半，相邻按钮的热区不会互相重叠（视觉底块本身不外扩）
    private var hitOutset: CGFloat { tier.gap / 2 }

    /// 只有可见且可用的按钮接收点击；空白区域返回 nil，事件落到内容视图。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in buttons where button.isEnabled && !button.isHidden {
            if button.frame.insetBy(dx: -hitOutset, dy: -hitOutset).contains(local) { return button }
        }
        return nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 按钮动作

    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func frameRateClicked() { onCycleFrameRate?() }
    @objc private func resetZoomClicked() { onResetZoom?() }
    @objc private func autoHideClicked() { onToggleHoverAutoHide?() }

    // MARK: - SF Symbols

    private static func symbol(_ name: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.symbolPointSize, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
    }
}

/// 控制条上的图标按钮：面板几乎不会成为 key window，第一次点击也要生效。
private final class ControlBarButton: NSButton {
    /// 底板颜色（常态 / 悬停 / 按下 / 激活由控制条按状态算好）：和按钮一样大的圆角块，不外扩
    var fillColor: NSColor = .clear {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }

    /// 按下态：只用来换底板和图标颜色，点击语义仍由 `NSButton` 自己的跟踪循环处理
    private(set) var isPressed = false
    /// 按下 / 松开时让控制条重算颜色
    var onPressedChanged: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onPressedChanged?()
        super.mouseDown(with: event) // 跟踪循环和动作派发都还是 NSButton 自己那一套
        isPressed = false
        onPressedChanged?()
    }
}

/// 按钮名称提示：HUD 材质全胶囊，画在控制条下方；淡入带 2pt 缓升，切换按钮时文字随图层过渡渐变，不接收鼠标。
private final class ControlBarHint: NSView {
    private enum Metrics {
        static let height: CGFloat = 20
        static let horizontalPadding: CGFloat = 8
        /// 文字宽度上限，超过的按尾部截断
        static let maximumTextWidth: CGFloat = 260
        static let fadeIn: TimeInterval = 0.10
        static let fadeOut: TimeInterval = 0.08
        /// 在相邻按钮之间切换时文字的过渡时长
        static let textFade: TimeInterval = 0.08
        /// 淡入时从下方上移的距离
        static let rise: CGFloat = 2
    }

    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    /// 只用来量文字宽度的同字体标签：`size(fitting:)` 不能改正在显示的 label，否则切换时的文字渐变就没了
    private let measuringLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.height / 2
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        addSubview(backdrop)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.wantsLayer = true // 切换按钮时的文字渐变用它的图层过渡
        addSubview(label)

        measuringLabel.font = label.font
        measuringLabel.lineBreakMode = .byTruncatingTail
        measuringLabel.usesSingleLineMode = true

        layoutContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        backdrop.frame = bounds
        label.frame = bounds.insetBy(dx: Metrics.horizontalPadding, dy: 0)
    }

    /// 提示块的尺寸（只量宽度，不改正在显示的 label：文字由 `show` 设置，切换时才能做渐变）
    func size(fitting text: String) -> NSSize {
        measuringLabel.stringValue = text
        let textSize = measuringLabel.sizeThatFits(NSSize(width: Metrics.maximumTextWidth, height: Metrics.height))
        return NSSize(width: ceil(textSize.width) + Metrics.horizontalPadding * 2, height: Metrics.height)
    }

    /// 淡入到指定位置；已经显示时只换文字和位置（在相邻按钮之间滑动时不会闪）
    func show(_ text: String, at frame: NSRect) {
        let wasVisible = !isHidden && alphaValue > 0.01
        self.frame = frame
        guard !wasVisible else {
            setText(text, animated: true)
            return
        }
        setText(text, animated: false)
        isHidden = false
        alphaValue = 0
        // 从下方 2pt 升到最终位置：和胶囊一样只动渲染层，frame 立刻就是终点，layout() 重摆也打不断
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -Metrics.rise
        rise.toValue = 0
        rise.duration = Metrics.fadeIn
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(rise, forKey: "appear")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        })
    }

    /// 换文字：已经显示时用图层淡入淡出（切换按钮时文字平滑渐变），否则直接换
    private func setText(_ text: String, animated: Bool) {
        guard label.stringValue != text else { return }
        if animated, let labelLayer = label.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Metrics.textFade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            labelLayer.add(fade, forKey: "text")
        }
        label.stringValue = text
    }

    /// 淡出；结束后 `isHidden`，不再占位
    func hide() {
        guard !isHidden else { return }
        layer?.removeAnimation(forKey: "appear")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue <= 0.01 else { return }
                self.isHidden = true
            }
        })
    }
}