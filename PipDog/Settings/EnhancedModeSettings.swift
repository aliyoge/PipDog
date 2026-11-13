import Foundation
import Observation

/// 键盘控制：`fn` 组合热键和指针停在小窗上时的裸键，默认关闭。
/// 这两类键只能靠 CGEventTap 拦，需要「辅助功能」权限；关闭时不装任何 tap。
@MainActor
@Observable
final class EnhancedModeSettings {
    static let shared = EnhancedModeSettings()
    static let defaultEnabled = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            onChange?()
        }
    }

    /// 由 AppDelegate 设置：开关变化时安装 / 移除事件 tap
    @ObservationIgnored var onChange: (() -> Void)?
    private static let enabledKey = "PipDog.enhancedMode"

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled
    }

    func restoreDefaults() {
        isEnabled = Self.defaultEnabled
    }
}