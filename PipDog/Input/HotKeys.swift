import Carbon.HIToolbox
import Foundation

/// 用 Carbon 的 RegisterEventHotKey 注册全局快捷键（不需要额外权限）。
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var reportedHandlerFailure = false
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5044_6F67 // "PDog"

    private init() {}

    /// 注册一个快捷键。keyCode 用 kVK_* 常量。失败时返回 false（通常是被别的 app 占用）。
    func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("PipDog: 注册快捷键失败（keyCode=\(keyCode)，status=\(status)）")
            return false
        }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }

    /// 安装快捷键事件处理器；失败时记日志并提示一次（之后每次注册都会重试安装）。
    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // 应用事件目标的回调在主线程上执行
            MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard status == noErr, handlerRef != nil else {
            handlerRef = nil
            NSLog("PipDog: 安装全局快捷键处理器失败（status=\(status)）")
            if !reportedHandlerFailure {
                reportedHandlerFailure = true
                Feedback.show("全局快捷键初始化失败（错误 \(status)），暂时只能从菜单使用")
            }
            return false
        }
        return true
    }
}
