import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

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
}
