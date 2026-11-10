import Foundation
import Observation
import ServiceManagement

/// 开机时启动：用 `SMAppService.mainApp` 把 PipDog 自己登记为登录项。
/// 以系统的登录项状态为准，不另存 UserDefaults；启动时不登记、不弹任何东西，只在用户打开开关时登记。
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// 最近一次读到的系统状态（打开设置窗口、菜单时会重新读取）
    private(set) var status: SMAppService.Status = .notRegistered

    private init() { refresh() }

    /// 已登记（包括等用户在系统设置里允许）
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    /// 已登记，但需要用户在「系统设置 › 通用 › 登录项与扩展」里允许
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    /// 打开或关闭开机时启动；失败时用提示浮层说明原因。
    /// openSettingsIfNeeded：需要用户允许时直接打开登录项设置（菜单里用；设置窗口里有按钮，不自动打开）。
    func setEnabled(_ enabled: Bool, openSettingsIfNeeded: Bool = false) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            refresh()
            if service.status == .notFound {
                Feedback.show("找不到可登记的应用，请先把 PipDog 装到「应用程序」文件夹再打开")
            } else {
                Feedback.show("无法\(enabled ? "打开" : "关闭")开机时启动：\(error.localizedDescription)")
            }
            return
        }
        refresh()
        guard enabled, requiresApproval else { return }
        Feedback.show("请在「系统设置 › 通用 › 登录项与扩展」里允许 PipDog，开机时才会启动")
        if openSettingsIfNeeded { openLoginItemsSettings() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
