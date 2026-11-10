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

    private static var notFoundMessage: String {
        String(localized: "Couldn't find an app to register. Move PipDog to the Applications folder and open it again.")
    }

    /// 打开或关闭开机时启动；已经是想要的状态时什么都不做。失败时用提示浮层说明原因（本地化文字），原始错误写日志。
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
            NSLog("PipDog: failed to \(enabled ? "register" : "unregister") the login item: \(error.localizedDescription)")
            Feedback.show(service.status == .notFound ? Self.notFoundMessage : Self.message(for: error, enabling: enabled))
            return
        }
        refresh()
        if enabled, status == .notRegistered || status == .notFound { // 没报错却没登记上
            NSLog("PipDog: login item status is still \(status.rawValue) after registering")
            Feedback.show(Self.notFoundMessage)
            return
        }
        guard enabled, requiresApproval else { return }
        Feedback.show(String(localized: "Allow PipDog in System Settings › General › Login Items & Extensions so it opens at login"))
        if openSettingsIfNeeded { openLoginItemsSettings() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// 把 ServiceManagement 的常见错误换成本地化的说明；别的错误用通用说明。
    private static func message(for error: any Error, enabling: Bool) -> String {
        let action = enabling
            ? String(localized: "turn on", comment: "Inserted into “Couldn't … Open at Login”")
            : String(localized: "turn off", comment: "Inserted into “Couldn't … Open at Login”")
        let nsError = error as NSError
        let generic = String(localized: "Couldn't \(action) Open at Login. Try again later, or set it in System Settings › General › Login Items & Extensions.")
        // 只认 ServiceManagement 的错误域：其他来源的错误即使错误码相同，也不套用下面的说明。
        // SMAppServiceErrorDomain 常量 macOS 15 才公开、kSMErrorDomainFramework 已弃用，所以直接比字符串
        guard ["SMAppServiceErrorDomain", "kSMErrorDomainFramework"].contains(nsError.domain) else { return generic }
        switch nsError.code {
        case kSMErrorLaunchDeniedByUser:
            return String(localized: "Couldn't \(action) Open at Login: macOS denied it. Allow PipDog in System Settings › General › Login Items & Extensions.")
        case kSMErrorInvalidSignature:
            return String(localized: "Couldn't \(action) Open at Login: PipDog's signature is invalid. Use an officially installed copy.")
        case kSMErrorAuthorizationFailure:
            return String(localized: "Couldn't \(action) Open at Login: no permission to change login items.")
        case kSMErrorJobNotFound, kSMErrorJobPlistNotFound, kSMErrorToolNotValid:
            return notFoundMessage
        case kSMErrorServiceUnavailable:
            return String(localized: "Couldn't \(action) Open at Login: the login items service isn't available right now. Try again later.")
        default:
            return generic
        }
    }
}
