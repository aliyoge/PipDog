import Foundation
import Observation

/// Chromium / Electron 兼容模式（默认关）。
///
/// PipDog 不重启任何 app：打开这个开关只是改变提示的内容——告诉用户「可以退出这个 app，
/// 再带 --disable-backgrounding-occluded-windows 重开」，这样它移到别的 Space 时不会停画。
/// 单独存一个 UserDefaults 键（原始 Bool），没有保存过时为关。
@MainActor
@Observable
final class ChromiumCompatibilitySettings {
    static let shared = ChromiumCompatibilitySettings()
    static let defaultEnabled = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    private static let enabledKey = "PipDog.chromiumCompatibilityMode"

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled
    }

    func restoreDefaults() { isEnabled = Self.defaultEnabled }
}