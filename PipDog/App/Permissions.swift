import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestIfNeeded() {
        if !hasAccessibility {
            let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt 的值，直接引用在 Swift 6 下不是并发安全的
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
