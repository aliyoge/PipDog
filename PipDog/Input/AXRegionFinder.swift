import ApplicationServices
import CoreGraphics
import Foundation

/// 用辅助功能接口找到鼠标下方一个合适的「容器」元素，返回它的范围（左上角原点的全局坐标）。
/// 不绑定主线程：AX 调用在目标 app 卡住时会阻塞，调用方应放在后台执行。
/// 整次查找有严格的总时限：每个 AX 请求之前都检查剩余时间，并把该请求的超时设成不超过剩余时间。
enum AXRegionFinder {
    static let containerRoles: Set<String> = [
        "AXScrollArea", "AXTextArea", "AXWebArea", "AXGroup", "AXTable", "AXList", "AXOutline",
    ]
    static let minimumSize = CGSize(width: 120, height: 60)
    /// 单次 AX 请求的超时上限，以及整次查找的总时限
    static let messagingTimeout: TimeInterval = 0.25
    static let totalTimeLimit: TimeInterval = 0.3
    /// 剩余时间少于这个值就不再发请求
    private static let minimumRequestTime: TimeInterval = 0.01

    /// - Parameters:
    ///   - point: 鼠标位置
    ///   - window: 鼠标下方的窗口；元素必须属于这个窗口的进程，且不能几乎占满整个窗口
    /// - Returns: 找到的范围；没找到或超时时为 nil（调用方改用固定大小的区域）
    static func containerFrame(at point: CGPoint, in window: WindowInfo) -> CGRect? {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let systemWide = AXUIElementCreateSystemWide()
        guard prepare(systemWide, before: deadline) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == window.pid else { return nil } // 本地调用，不发消息

        for _ in 0..<25 where Date() < deadline {
            let role = string(of: element, "AXRole", before: deadline)
            if role == "AXWindow" || role == "AXApplication" { return nil }
            if let role, containerRoles.contains(role), let frame = frame(of: element, before: deadline),
               isSensible(frame, in: window.bounds) {
                return frame
            }
            guard let parent = child(of: element, "AXParent", before: deadline) else { return nil }
            element = parent
        }
        return nil
    }

    private static func isSensible(_ frame: CGRect, in window: CGRect) -> Bool {
        frame.width >= minimumSize.width && frame.height >= minimumSize.height
            && !(frame.width >= window.width * 0.95 && frame.height >= window.height * 0.95)
    }

    /// 时间还够的话，把这个元素的请求超时设成「剩余时间」和单次上限中较小的那个，返回 true。
    private static func prepare(_ element: AXUIElement, before deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= minimumRequestTime else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, messagingTimeout)))
        return true
    }

    // MARK: - AX 属性读取（每个请求之前都检查时限）

    private static func attribute(_ element: AXUIElement, _ name: String, before deadline: Date) -> CFTypeRef? {
        guard prepare(element, before: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(of element: AXUIElement, _ name: String, before deadline: Date) -> String? {
        attribute(element, name, before: deadline) as? String
    }

    private static func child(of element: AXUIElement, _ name: String, before deadline: Date) -> AXUIElement? {
        guard let value = attribute(element, name, before: deadline), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func axValue(of element: AXUIElement, _ name: String, before deadline: Date) -> AXValue? {
        guard let value = attribute(element, name, before: deadline), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func frame(of element: AXUIElement, before deadline: Date) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(of: element, "AXPosition", before: deadline),
              AXValueGetValue(position, .cgPoint, &origin),
              let sizeValue = axValue(of: element, "AXSize", before: deadline),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
