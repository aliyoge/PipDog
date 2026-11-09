import ApplicationServices
import CoreGraphics
import Foundation

/// 修饰键 + 双击用的 CGEventTap，跑在自己的线程和 run loop 上：
/// 这个 tap 是会话级、插在最前、可修改事件的，系统里每次左键按下 / 松开都要等它返回，
/// 放在主线程的话，主线程一卡全系统的点击都会跟着卡。
///
/// tap 线程只读写这里用锁保护的状态（配置快照、PipDog 自己窗口的矩形），不碰任何主线程对象；
/// 需要做事时通过 onTrigger / onTapLost 回调（由创建方负责切回主线程）。
final class ClickTap: @unchecked Sendable {
    private static let relevantFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    private let lock = NSLock()
    private var enabled = false
    private var modifiers: CGEventFlags = []
    /// PipDog 自己可点击的窗口（左上角原点的全局坐标），点在上面时不拦截
    private var ownWindowRects: [CGRect] = []
    private var swallowNextMouseUp = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopRequested = false

    /// 识别到触发双击时调用（在 tap 线程上），参数是左上角原点的全局坐标
    private let onTrigger: @Sendable (CGPoint) -> Void
    /// tap 意外失效（系统作废、权限被撤销）时调用（在 tap 线程上）
    private let onTapLost: @Sendable () -> Void

    init(onTrigger: @escaping @Sendable (CGPoint) -> Void, onTapLost: @escaping @Sendable () -> Void) {
        self.onTrigger = onTrigger
        self.onTapLost = onTapLost
    }

    // MARK: - 主线程调用

    func setConfig(enabled: Bool, modifiers: CGEventFlags) {
        lock.withLock {
            self.enabled = enabled
            self.modifiers = modifiers.intersection(Self.relevantFlags)
        }
    }

    func setOwnWindowRects(_ rects: [CGRect]) {
        lock.withLock { ownWindowRects = rects }
    }

    /// 启动 tap 线程，等它建好 tap 再返回。建不了 tap（通常是没有辅助功能权限）时返回 false。
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready: ready) }
        thread.name = "PipDog.clickTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            stop()
            return false
        }
        return lock.withLock { tap != nil }
    }

    /// 请求停止：先关掉 tap（事件立即不再经过 PipDog），再让 tap 线程退出。可以重复调用。
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
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<ClickTap>.fromOpaque(refcon).takeUnretainedValue()
                return context.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("PipDog: 创建鼠标事件 tap 失败")
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
            swallowNextMouseUp = false
        }
        if lost { onTapLost() }
    }

    /// 返回 true 表示吞掉这个事件。在 tap 线程上执行，必须尽快返回。
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 被系统暂停：还有权限就重新打开；权限被撤销了就通知主线程拆掉 tap、退回旁观模式
            if AXIsProcessTrusted() {
                if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                onTapLost()
            }
            return false
        case .leftMouseDown:
            let clickState = event.getIntegerValueField(.mouseEventClickState)
            let flags = event.flags.intersection(Self.relevantFlags)
            let location = event.location
            let trigger = lock.withLock { () -> Bool in
                // 任何一次按下都先清掉上一次留下的标志，避免误吞一次正常的松开
                swallowNextMouseUp = false
                guard enabled, clickState == 2, flags == modifiers,
                      !ownWindowRects.contains(where: { $0.contains(location) }) else { return false }
                swallowNextMouseUp = true
                return true
            }
            if trigger { onTrigger(location) }
            return trigger
        case .leftMouseUp:
            return lock.withLock {
                guard swallowNextMouseUp else { return false }
                swallowNextMouseUp = false
                return true
            }
        default:
            return false
        }
    }
}
