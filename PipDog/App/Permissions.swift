import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
enum Permissions {
    enum Kind { case screenRecording, accessibility }

    enum ScreenRecordingState {
        case authorized, restartRequired, notAuthorized

        /// 菜单里显示的状态
        var title: String {
            switch self {
            case .authorized: String(localized: "Granted")
            case .restartRequired: String(localized: "Granted, Relaunch Required")
            case .notAuthorized: String(localized: "Not Granted")
            }
        }
    }

    // 在 applicationDidFinishLaunching 中立即读取，避免第一次 PiP 时才取启动快照。
    static let hadScreenRecordingAtLaunch = CGPreflightScreenCaptureAccess()
    private static var captureSucceeded = false
    private static var requestedScreenRecording = false
    private static var showingAlert = false
    private static var restarting = false

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var screenRecordingName: String {
        if #available(macOS 15, *) { return String(localized: "Screen & System Audio Recording") }
        return String(localized: "Screen Recording")
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

    /// 抓取中途出错时用：除了上面的判断，启动时有权限、现在 preflight 却是 false，也当作运行中撤销了权限
    /// （启动时没有权限的话，运行中授权后 preflight 可能一直是 false，不能这样判断）。
    static func isScreenRecordingLost(_ error: any Error) -> Bool {
        if isScreenRecordingError(error) { return true }
        guard hadScreenRecordingAtLaunch, !CGPreflightScreenCaptureAccess() else { return false }
        captureSucceeded = false
        return true
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
                Feedback.show(String(localized: "Turn on PipDog in System Settings › Privacy & Security › \(screenRecordingName), then relaunch PipDog (try PiP again or click the permission status in the menu)"))
                return
            }
            showScreenRecordingAlert()
        case .accessibility:
            // 修饰键 + 双击和「单击小窗把原窗口移到屏幕边上」需要；调用方只在用户用到这些功能时调用
            guard !hasAccessibility else { return }
            // 只用系统授权框：登记到「辅助功能」列表，不再叠加自定义 NSAlert。
            NSApp.activate()
            Feedback.show(message ?? String(localized: "Turn on PipDog in System Settings › Privacy & Security › Accessibility"))
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
            alert.messageText = String(localized: "\(screenRecordingName) is granted. Relaunch PipDog for it to take effect.")
            alert.informativeText = String(localized: "After relaunching, PipDog can capture window content.")
            alert.addButton(withTitle: String(localized: "Relaunch PipDog"))
            alert.addButton(withTitle: String(localized: "Later"))
            if alert.runModal() == .alertFirstButtonReturn { relaunch() }
        } else {
            alert.messageText = String(localized: "PipDog needs \(screenRecordingName) permission")
            alert.informativeText = String(localized: "Turn on PipDog in System Settings › Privacy & Security › \(screenRecordingName), then click “Relaunch PipDog”. The permission status may take a moment to update; you can relaunch even if it still shows as not granted.")
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Relaunch PipDog"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // 自定义弹窗已关闭后才允许系统请求；每次运行最多登记一次。
                if !requestedScreenRecording {
                    requestedScreenRecording = true
                    _ = CGRequestScreenCaptureAccess()
                }
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                   !NSWorkspace.shared.open(url) {
                    Feedback.show(String(localized: "Couldn't open System Settings. Go to Privacy & Security › \(screenRecordingName) manually."))
                }
            } else if response == .alertSecondButtonReturn {
                relaunch()
            }
        }
    }

    /// 启动一个新实例再退出自己（屏幕录制授权后、切换语言后用）。
    static func relaunch() {
        guard !restarting else { return }
        restarting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let launched = app != nil && error == nil
            if let error { NSLog("PipDog: relaunch failed: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                restarting = false
                if launched {
                    SourceWindowActivator.restoreAllStashed() // 先把移到屏幕边上的窗口放回去
                    NSApp.terminate(nil)
                } else {
                    Feedback.show(String(localized: "Couldn't relaunch PipDog. Quit PipDog from the menu and open it again."))
                }
            }
        }
    }
}
