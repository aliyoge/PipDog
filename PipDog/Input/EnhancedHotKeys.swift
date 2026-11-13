import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 键盘控制用的 CGEventTap：Carbon 的 RegisterEventHotKey 注册不了 `fn` 修饰键，
/// 悬停时的裸键（= - F D ⌫）也只有指针停在小窗上时才该拦截，所以这两类键都靠 tap 自己判断。
///
/// 和 ClickTap 一样跑在自己的线程和 run loop 上：这个 tap 插在会话级最前面，每次按键都要等它返回，
/// 放在主线程的话主线程一卡全系统的打字都会跟着卡。
///
/// tap 线程只读写用锁保护的状态（小窗矩形），不碰任何主线程对象；识别到要处理的键时通过回调
/// （由创建方负责切回主线程）。`fn` 轻点靠 flagsChanged 的时间差判断，同样只在 tap 线程读写。
final class EnhancedHotKeys: @unchecked Sendable {
    /// fn 组合键：等价于两个全局快捷键
    enum GlobalKey: Sendable {
        case pipWindow, selectRegion
    }

    /// 指针停在小窗上时生效的裸键
    enum HoverKey: Sendable {
        case zoomIn, zoomOut, cycleFrameRate, toggleStaticFrameRate, toggleHidden, close
    }

    /// 轻点 fn 的最长时间（秒）
    private static let functionTapLimit: CFTimeInterval = 0.4

    private let lock = NSLock()
    /// 指针停在这些矩形里才算悬停（左上角原点的全局坐标，和 CGEvent.location 同一套坐标系）
    private var panelRects: [CGRect] = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopRequested = false

    /// `fn` 按下的时间（nil：没按着）；按着期间又按了别的键就作废（functionTapSpoiled）。只有 tap 线程碰。
    private var functionPressedAt: CFAbsoluteTime?
    private var functionTapSpoiled = false

    /// 识别到 fn 组合键时调用（在 tap 线程上）
    private let onGlobalKey: @Sendable (GlobalKey) -> Void
    /// 识别到悬停裸键时调用（在 tap 线程上）
    private let onHoverKey: @Sendable (HoverKey) -> Void
    /// tap 意外失效（系统作废、辅助功能被撤销）时调用（在 tap 线程上）
    private let onTapLost: @Sendable () -> Void

    init(onGlobalKey: @escaping @Sendable (GlobalKey) -> Void,
         onHoverKey: @escaping @Sendable (HoverKey) -> Void,
         onTapLost: @escaping @Sendable () -> Void) {
        self.onGlobalKey = onGlobalKey
        self.onHoverKey = onHoverKey
        self.onTapLost = onTapLost
    }

    // MARK: - 主线程调用

    /// 指针下方的小窗矩形（左上角原点）：只有指针落在里面时才拦截裸键
    func setPanelRects(_ rects: [CGRect]) {
        lock.withLock { panelRects = rects }
    }

    /// 启动 tap 线程，等它建好 tap 再返回。建不了 tap（通常是没有辅助功能权限）时返回 false。
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready: ready) }
        thread.name = "PipDog.enhancedHotKeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            stop()
            return false
        }
        return lock.withLock { tap != nil }
    }

    /// 请求停止：先关掉 tap（按键立即不再经过 PipDog），再让 tap 线程退出。可以重复调用。
    func stop() {
        let (tap, runLoop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            stopRequested = true
            return (self.tap, self.runLoop)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: - tap 线程

    private func run(ready: DispatchSemaphore) {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<EnhancedHotKeys>.fromOpaque(refcon).takeUnretainedValue()
                return context.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("PipDog: failed to create the keyboard event tap")
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop: CFRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        let alreadyStopped = lock.withLock { () -> Bool in
            self.tap = tap
            self.runLoop = runLoop
            return stopRequested
        }
        if !alreadyStopped { CGEvent.tapEnable(tap: tap, enable: true) }
        ready.signal()

        // 用带超时的 RunInMode 循环，避免 stop() 恰好在进入 run loop 之前调用时错过 CFRunLoopStop
        var lost = false
        while !lock.withLock({ stopRequested }) {
            let result = CFRunLoopRunInMode(.defaultMode, 1, false)
            if result == .finished || !CFMachPortIsValid(tap) { // source 被移除：tap 已被系统作废
                lost = true
                break
            }
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        lock.withLock {
            self.tap = nil
            self.runLoop = nil
        }
        if lost { onTapLost() }
    }

    /// 返回 true 表示吞掉这个事件。在 tap 线程上执行，必须尽快返回。
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 被系统暂停：还有权限、并且没有在停止，就重新打开；权限被撤销了就通知主线程拆掉 tap
            let (tap, stopped) = lock.withLock { (self.tap, stopRequested) }
            guard !stopped else { return false }
            if AXIsProcessTrusted() {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                onTapLost()
            }
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        default:
            return false
        }
    }

    /// fn + P / fn + ⇧ + P 走全局快捷键，其余（没有 ⌘⌃⌥ 时）是指针停在小窗上才生效的裸键。
    /// 只吞掉列表里的键，其他按键原样穿过去。
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        functionTapSpoiled = true // fn 按着时又按了别的键：这次不算轻点 fn

        if flags.contains(.maskSecondaryFn), !flags.contains(.maskCommand), !flags.contains(.maskControl),
           !flags.contains(.maskAlternate), keyCode == kVK_ANSI_P {
            if !isRepeat {
                let action: GlobalKey = flags.contains(.maskShift) ? .selectRegion : .pipWindow
                onGlobalKey(action)
            }
            return true
        }

        // 悬停裸键：带 ⌘⌃⌥ 或 fn 的组合留给别的 app 和系统快捷键；指针不在小窗上也不拦
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
              !flags.contains(.maskSecondaryFn) else { return false }
        let overPiP = lock.withLock { panelRects.contains { $0.contains(event.location) } }
        guard overPiP else { return false }
        let key: HoverKey?
        switch keyCode {
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: key = .zoomIn
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: key = .zoomOut
        case kVK_ANSI_F: key = .cycleFrameRate
        case kVK_ANSI_D: key = .toggleStaticFrameRate
        case kVK_Delete, kVK_ForwardDelete: key = .close
        default: key = nil
        }
        guard let key else { return false }
        // 按住不连发：帧率、静止降帧、关闭只算按下那一次（缩放可以按住连发）
        if isRepeat {
            switch key {
            case .zoomIn, .zoomOut: break
            case .cycleFrameRate, .toggleStaticFrameRate, .toggleHidden, .close: return true
            }
        }
        onHoverKey(key)
        return true
    }

    /// 轻点 fn（按下又松开，不超过 0.4 秒，期间没按别的键或修饰键）：隐藏 / 显示指针下方的小窗。
    /// 这只是一种手势，不吞事件。
    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == kVK_Function else {
            // fn 按着期间又按了别的修饰键（⇧⌘⌥⌃）：这次不算轻点
            if !event.flags.intersection(Self.tapSpoilingModifiers).isEmpty { functionTapSpoiled = true }
            return
        }
        if event.flags.contains(.maskSecondaryFn) {
            functionPressedAt = CFAbsoluteTimeGetCurrent()
            // 按下 fn 时已经按着别的修饰键或普通键：从一开始就不是单独轻点 fn
            functionTapSpoiled = !event.flags.intersection(Self.tapSpoilingModifiers).isEmpty
                || Self.nonModifierKeyDown()
        } else {
            defer { functionPressedAt = nil }
            guard let start = functionPressedAt, !functionTapSpoiled,
                  CFAbsoluteTimeGetCurrent() - start <= Self.functionTapLimit else { return }
            onHoverKey(.toggleHidden)
        }
    }

    /// 会让 fn 轻点作废的修饰键（fn 本身不算）
    private static var tapSpoilingModifiers: CGEventFlags {
        [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    }

    /// 有没有修饰键以外的键按着（fn + 字母这类组合）：按下 fn 时会重置轻点状态，
    /// 之前按下的键不会再送 keyDown，所以这里直接读按键状态。
    private static func nonModifierKeyDown() -> Bool {
        let modifierKeys: ClosedRange<CGKeyCode> = 54...63 // ⌘ ⇧ ⇪ ⌥ ⌃（左右）和 fn
        return (0..<128).contains { (code: CGKeyCode) in
            !modifierKeys.contains(code) && CGEventSource.keyState(.combinedSessionState, key: code)
        }
    }
}