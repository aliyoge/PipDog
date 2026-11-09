import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestIfNeeded() {
        if !hasAccessibility {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
