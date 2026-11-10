import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
enum Permissions {
    enum Kind { case screenRecording, accessibility }

    enum ScreenRecordingState: String {
        case authorized = "已授权"
        case restartRequired = "已授权，需重新启动"
        case notAuthorized = "未授权"
    }

    // 在 applicationDidFinishLaunching 中立即读取，避免第一次 PiP 时才取启动快照。
    static let hadScreenRecordingAtLaunch = CGPreflightScreenCaptureAccess()
    private static var captureSucceeded = false
    private static var requestedScreenRecording = false
    private static var showingAlert = false
    private static var restarting = false

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var screenRecordingName: String {
        if #available(macOS 15, *) { return "屏幕与系统录音" }
        return "屏幕录制"
    }

    static var screenRecordingState: ScreenRecordingState {
        // 实际抓取成功比可能过时的 preflight 更可信；明确拒绝时清除此记录。
        if captureSucceeded { return .authorized }
        guard CGPreflightScreenCaptureAccess() else { return .notAuthorized }
        return hadScreenRecordingAtLaunch ? .authorized : .restartRequired
    }

    static func recordCaptureSuccess() {
        captureSucceeded = true
    }

    /// 成功抓取后不再因启动快照或过时的 preflight 误报；明确拒绝仍需重新引导。
    static func isScreenRecordingError(_ error: any Error) -> Bool {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain, failure.code == SCStreamError.Code.userDeclined.rawValue {
            captureSucceeded = false
            return true
        }
        return !captureSucceeded && (!hadScreenRecordingAtLaunch || !CGPreflightScreenCaptureAccess())
    }

    /// afterFailure：由 PiP 失败触发（而不是用户点菜单）。message：辅助功能引导时替换默认提示。
    static func showAlert(_ kind: Kind, afterFailure: Bool = false, message: String? = nil) {
        switch kind {
        case .screenRecording:
            // 本次运行第一次因未授权失败：只发起系统请求（登记到列表，系统框自带「打开系统设置」），
            // 配一条浮层说明，不弹自己的 NSAlert，避免和系统框（或 ScreenCaptureKit 自己弹的框）叠在一起。
            if afterFailure, !requestedScreenRecording, screenRecordingState == .notAuthorized {
                requestedScreenRecording = true
                _ = CGRequestScreenCaptureAccess()
                Feedback.show("请在「系统设置 › 隐私与安全性 › \(screenRecordingName)」里打开 PipDog，然后重新启动 PipDog（再试一次 PiP 或点菜单里的权限状态）")
                return
            }
            showScreenRecordingAlert()
        case .accessibility:
            // 修饰键 + 双击和「单击小窗把原窗口移到屏幕边上」需要；调用方只在用户用到这些功能时调用
            guard !hasAccessibility else { return }
            // 只用系统授权框：登记到「辅助功能」列表，不再叠加自定义 NSAlert。
            NSApp.activate()
            Feedback.show(message ?? "请在「系统设置 › 隐私与安全性 › 辅助功能」里打开 PipDog")
            let key = "AXTrustedCheckOptionPrompt" // 避免 Swift 6 访问非并发安全的全局 CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    private static func showScreenRecordingAlert() {
        guard !showingAlert else { return }
        showingAlert = true
        defer { showingAlert = false }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        if screenRecordingState == .restartRequired {
            alert.messageText = "「\(screenRecordingName)」已授权，需要重新启动 PipDog 才能生效"
            alert.informativeText = "重新启动后即可抓取窗口画面。"
            alert.addButton(withTitle: "重新启动 PipDog")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn { restart() }
        } else {
            alert.messageText = "PipDog 需要「\(screenRecordingName)」权限"
            alert.informativeText = "请在「系统设置 › 隐私与安全性 › \(screenRecordingName)」里打开 PipDog，再点「重新启动 PipDog」。授权状态可能延迟刷新；即使仍显示未授权，也可以重新启动。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "重新启动 PipDog")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // 自定义弹窗已关闭后才允许系统请求；每次运行最多登记一次。
                if !requestedScreenRecording {
                    requestedScreenRecording = true
                    _ = CGRequestScreenCaptureAccess()
                }
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                   !NSWorkspace.shared.open(url) {
                    Feedback.show("无法打开系统设置，请手动前往「隐私与安全性 › \(screenRecordingName)」")
                }
            } else if response == .alertSecondButtonReturn {
                restart()
            }
        }
    }

    private static func restart() {
        guard !restarting else { return }
        restarting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let launched = app != nil && error == nil
            let message = error?.localizedDescription ?? "未能启动新实例"
            DispatchQueue.main.async {
                restarting = false
                if launched {
                    SourceWindowActivator.restoreAllStashed() // 先把移到屏幕边上的窗口放回去
                    NSApp.terminate(nil)
                } else {
                    Feedback.show("重新启动 PipDog 失败：\(message)")
                }
            }
        }
    }
}
