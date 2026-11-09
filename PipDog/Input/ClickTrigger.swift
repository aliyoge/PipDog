import AppKit
import CoreGraphics

/// 监听全局「修饰键 + 双击」，触发区域 PiP。回调参数是左上角原点的全局坐标。
/// - 有辅助功能权限时用 CGEventTap（会话级、插在最前、可修改事件）：修饰键匹配时，
///   把触发用的第二次按下和对应的松开吞掉，目标 app 只收到第一次单击。
/// - 没有权限时退回 NSEvent 全局监听（只能旁观，双击仍会传给目标 app），并每 3 秒重试建立 tap。
@MainActor
final class ClickTrigger {
    var onTrigger: ((CGPoint) -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var retryTimer: Timer?
    private var swallowNextMouseUp = false

    func start() {
        guard tap == nil, fallbackMonitor == nil else { return }
        if installTap() { return }
        installFallbackMonitor()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryTap() }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        removeFallbackMonitor()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        swallowNextMouseUp = false
    }

    // MARK: - CGEventTap

    private func retryTap() {
        guard installTap() else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        removeFallbackMonitor()
    }

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.hasAccessibility else { return false }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        // 回调在主运行循环上执行（下面把 source 加到了主 run loop），所以可以 assumeIsolated
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let trigger = Unmanaged<ClickTrigger>.fromOpaque(refcon).takeUnretainedValue()
                let clickState = event.getIntegerValueField(.mouseEventClickState)
                let flags = event.flags
                let location = event.location
                let swallow = MainActor.assumeIsolated {
                    trigger.handleTap(type: type, clickState: clickState, flags: flags, location: location)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("PipDog: 创建鼠标事件 tap 失败，改用只能旁观的全局监听")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    /// 返回 true 表示吞掉这个事件。
    private func handleTap(type: CGEventType, clickState: Int64, flags: CGEventFlags, location: CGPoint) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown:
            guard clickState == 2, matches(Self.modifiers(from: flags)), !isOverOwnWindow(location) else { return false }
            swallowNextMouseUp = true
            // 尽快从 tap 回调返回，真正的处理放到下一轮主循环
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onTrigger?(location) }
            }
            return true
        case .leftMouseUp:
            guard swallowNextMouseUp else { return false }
            swallowNextMouseUp = false
            return true
        default:
            return false
        }
    }

    // MARK: - 退回方案：只能旁观的全局监听

    private func installFallbackMonitor() {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clickCount = event.clickCount
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handleObservedClick(clickCount: clickCount, flags: flags) }
        }
    }

    private func removeFallbackMonitor() {
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        fallbackMonitor = nil
    }

    private func handleObservedClick(clickCount: Int, flags: NSEvent.ModifierFlags) {
        guard clickCount == 2, matches(flags) else { return }
        guard Permissions.hasAccessibility else {
            Permissions.showAlert(.accessibility)
            return
        }
        onTrigger?(Geometry.mouseLocationTopLeft)
    }

    // MARK: - 匹配

    /// 修饰键精确匹配设置里的组合（忽略 Caps Lock / fn / 小键盘标志）。
    private func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let config = ShortcutSettings.shared.config
        let pressed = flags.intersection([.control, .option, .shift, .command])
        return config.clickEnabled && pressed == config.clickModifiers
    }

    private static func modifiers(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    /// 点在 PipDog 自己的窗口（PiP 面板、设置窗口）上时不拦截。
    private func isOverOwnWindow(_ topLeftPoint: CGPoint) -> Bool {
        let point = Geometry.flipped(topLeftPoint)
        return NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }
    }
}
