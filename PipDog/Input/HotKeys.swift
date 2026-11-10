import Carbon.HIToolbox
import Foundation

/// 用 Carbon 的 RegisterEventHotKey 注册全局快捷键（不需要额外权限）。
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5044_6F67 // "PDog"

    /// 注册结果：区分「快捷键处理器装不上」（所有快捷键都用不了）和「这一个组合注册失败」。
    enum Registration: Equatable {
        case registered
        /// 全局快捷键事件处理器安装失败
        case handlerUnavailable(OSStatus)
        /// RegisterEventHotKey 失败。注意：这里用非独占注册（options 为 0），其他 app 注册了同一组合也不会失败
        /// （只有双方都独占注册才返回 eventHotKeyExistsErr），所以和其他 app 的冲突检测不出来。
        case failed(OSStatus)
    }

    private init() {}

    /// 注册一个快捷键。keyCode 用 kVK_* 常量。
    func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) -> Registration {
        if let status = installHandlerIfNeeded() { return .handlerUnavailable(status) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("PipDog: 注册快捷键失败（keyCode=\(keyCode)，status=\(status)）")
            return .failed(status == noErr ? OSStatus(paramErr) : status)
        }
        refs.append(ref)
        actions[id] = action
        return .registered
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }

    /// 安装快捷键事件处理器；成功（或已安装）返回 nil，失败返回错误码并记日志（之后每次注册都会重试安装）。
    /// 给用户的提示由 ShortcutSettings 统一给：启动时提示一次，设置里显示红字。
    private func installHandlerIfNeeded() -> OSStatus? {
        guard handlerRef == nil else { return nil }
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
            return status == noErr ? OSStatus(paramErr) : status
        }
        return nil
    }
}
