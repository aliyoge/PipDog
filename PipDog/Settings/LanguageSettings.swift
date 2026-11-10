import AppKit
import Observation

/// 界面语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 语言名用各自的语言写；「跟随系统」跟着当前界面语言
    var title: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

/// 界面语言设置：写 app 自己域里的 AppleLanguages（跟随系统就删掉这个键），macOS 在启动时读取，
/// 所以改了以后提示重新启动。跟随系统时由系统按首选语言在 en / zh-Hans 里挑。
@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()

    private(set) var language: AppLanguage
    private static let key = "AppleLanguages"

    private init() { language = Self.saved }

    /// 只看 app 自己的域：standard.array(forKey:) 会读到全局域里系统的语言列表
    private static var saved: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
        guard let first = (domain?[key] as? [String])?.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        if new == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([new.rawValue], forKey: Self.key)
        }
        // 等选择器（或恢复默认按钮）的事件处理完再弹窗
        Task { @MainActor in Self.askToRelaunch() }
    }

    func restoreDefaults() { setLanguage(.system) }

    private static func askToRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch PipDog to use the new language?")
        alert.informativeText = String(localized: "The language changes after PipDog relaunches.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { Permissions.relaunch() }
    }
}
