import AppKit
import Observation
import ServiceManagement

/// 开机时启动：用 `SMAppService.mainApp` 把 PipDog 自己登记为登录项。
/// 以系统的登录项状态为准，不另存 UserDefaults；启动时不登记、不弹任何东西，只在用户打开开关时登记。
/// 用户可能在系统设置里改了状态：PipDog 变成前台、打开设置窗口、打开菜单时都重新读取。
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// 最近一次读到的系统状态
    private(set) var status: SMAppService.Status = .notRegistered
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private init() {
        refresh()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchAtLogin.shared.refresh() }
        }
    }

    /// 已登记（包括等用户在系统设置里允许）
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    /// 已登记，但需要用户在「系统设置 › 通用 › 登录项与扩展」里允许
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    private static let notFoundMessage = "找不到可登记的应用，请先把 PipDog 装到「应用程序」文件夹再打开"

    /// 打开或关闭开机时启动；已经是想要的状态时什么都不做。失败时用提示浮层说明原因（中文），原始错误写日志。
    /// openSettingsIfNeeded：需要用户允许时直接打开登录项设置（菜单里用；设置窗口里有按钮，不自动打开）。
    func setEnabled(_ enabled: Bool, openSettingsIfNeeded: Bool = false) {
        refresh()
        guard isEnabled != enabled else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            refresh()
            guard isEnabled != enabled else { return } // 其实已经是想要的状态（例如已在系统设置里删掉）
            NSLog("PipDog: \(enabled ? "登记" : "取消")登录项失败：\(error.localizedDescription)")
            Feedback.show(service.status == .notFound ? Self.notFoundMessage : Self.message(for: error, enabling: enabled))
            return
        }
        refresh()
        if enabled, status == .notRegistered || status == .notFound { // 没报错却没登记上
            NSLog("PipDog: 登记登录项后状态仍为 \(status.rawValue)")
            Feedback.show(Self.notFoundMessage)
            return
        }
        guard enabled, requiresApproval else { return }
        Feedback.show("请在「系统设置 › 通用 › 登录项与扩展」里允许 PipDog，开机时才会启动")
        if openSettingsIfNeeded { openLoginItemsSettings() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// 把 ServiceManagement 的常见错误换成中文说明；别的错误用通用说明。
    private static func message(for error: any Error, enabling: Bool) -> String {
        let action = enabling ? "打开" : "关闭"
        let nsError = error as NSError
        let generic = "无法\(action)开机时启动，请稍后再试，或在「系统设置 › 通用 › 登录项与扩展」里手动设置"
        // 只认 ServiceManagement 的错误域：其他来源的错误即使错误码相同，也不套用下面的说明。
        // SMAppServiceErrorDomain 常量 macOS 15 才公开、kSMErrorDomainFramework 已弃用，所以直接比字符串
        guard ["SMAppServiceErrorDomain", "kSMErrorDomainFramework"].contains(nsError.domain) else { return generic }
        switch nsError.code {
        case kSMErrorLaunchDeniedByUser:
            return "无法\(action)开机时启动：被系统拒绝，请在「系统设置 › 通用 › 登录项与扩展」里允许 PipDog"
        case kSMErrorInvalidSignature:
            return "无法\(action)开机时启动：PipDog 的签名无效，请使用正式安装的版本"
        case kSMErrorAuthorizationFailure:
            return "无法\(action)开机时启动：没有修改登录项的权限"
        case kSMErrorJobNotFound, kSMErrorJobPlistNotFound, kSMErrorToolNotValid:
            return notFoundMessage
        case kSMErrorServiceUnavailable:
            return "无法\(action)开机时启动：登录项服务暂时不可用，请稍后再试"
        default:
            return generic
        }
    }
}
