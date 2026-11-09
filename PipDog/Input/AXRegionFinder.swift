import ApplicationServices
import CoreGraphics

/// 用辅助功能接口找到鼠标下方一个合适的「容器」元素，返回它的范围（左上角原点的全局坐标）。
@MainActor
enum AXRegionFinder {
    static let containerRoles: Set<String> = [
        "AXScrollArea", "AXTextArea", "AXWebArea", "AXGroup", "AXTable", "AXList", "AXOutline",
    ]
    static let minimumSize = CGSize(width: 120, height: 60)

    /// - Parameters:
    ///   - point: 鼠标位置
    ///   - window: 鼠标下方的窗口；元素必须属于这个窗口的进程，且不能几乎占满整个窗口
    static func containerFrame(at point: CGPoint, in window: WindowInfo) -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == window.pid else { return nil }

        for _ in 0..<25 {
            let role = string(of: element, "AXRole")
            if role == "AXWindow" || role == "AXApplication" { break }
            if let role, containerRoles.contains(role), let frame = frame(of: element), isSensible(frame, in: window.bounds) {
                return frame
            }
            guard let parent = child(of: element, "AXParent") else { break }
            element = parent
        }
        return nil
    }

    private static func isSensible(_ frame: CGRect, in window: CGRect) -> Bool {
        frame.width >= minimumSize.width && frame.height >= minimumSize.height
            && !(frame.width >= window.width * 0.95 && frame.height >= window.height * 0.95)
    }

    // MARK: - AX 属性读取

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(of element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func child(of element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func axValue(of element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(of: element, "AXPosition"), AXValueGetValue(position, .cgPoint, &origin),
              let sizeValue = axValue(of: element, "AXSize"), AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
