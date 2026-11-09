import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
enum Permissions {
    enum Kind {
        case screenRecording, accessibility

        var title: String {
            switch self {
            case .screenRecording: "PipDog 需要「屏幕录制」权限"
            case .accessibility: "PipDog 需要「辅助功能」权限"
            }
        }

        var message: String {
            switch self {
            case .screenRecording:
                "没有屏幕录制权限就无法显示窗口画面。请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」里打开 PipDog。授权后可能需要重新启动 PipDog。"
            case .accessibility:
                "修饰键 + 双击需要辅助功能权限来识别鼠标下方的区域，并拦截触发用的那次双击。请在「系统设置 › 隐私与安全性 › 辅助功能」里打开 PipDog。"
            }
        }

        var settingsURL: URL? {
            switch self {
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 启动时调用：未授权时弹出系统自己的授权提示。
    static func requestIfNeeded() {
        requestAccessibility()
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// 未授权时弹出系统的辅助功能授权提示。
    static func requestAccessibility() {
        guard !hasAccessibility else { return }
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt 的值，直接引用在 Swift 6 下不是并发安全的
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 菜单「检查权限」：都有就提示一下；缺哪个就弹对应的说明。
    static func checkAndExplain() {
        if !hasScreenRecording {
            showAlert(.screenRecording)
        } else if !hasAccessibility {
            showAlert(.accessibility)
        } else {
            Feedback.show("屏幕录制和辅助功能权限都已授予")
        }
    }

    /// 抓取失败是否是因为没有屏幕录制权限。
    static func isScreenRecordingError(_ error: any Error) -> Bool {
        if let error = error as? SCStreamError, error.code == .userDeclined { return true }
        return !hasScreenRecording
    }

    /// 说明缺少的权限，提供「打开系统设置」按钮直接跳到对应页面。
    static func showAlert(_ kind: Kind) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = kind.title
        alert.informativeText = kind.message
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}
