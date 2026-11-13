import Foundation

/// 可能停止离屏刷新的 Chromium / Electron 应用。
///
/// 现象：这类应用把窗口放到别的 Space、或被完全遮挡后不再绘制，ScreenCaptureKit 只能拿到最后一帧。
/// 项目不做自动重启，所以这里只用来「提示用户」：名单里的 app 命中可疑停帧时提示一次。
/// 名单不全时靠 bundle 前缀兜底；认错了代价也只是一次（每次运行每个 app 最多一次）提示。
enum SourceAppCompatibility {
    /// 已知用 Chromium / Electron 的应用（参照 my-window-pip 的 SourceAppCompatibility 名单）
    private static let knownChromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.openai.codex",          // ChatGPT
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap",  // Slack
        "com.hnc.Discord",           // Discord
        "md.obsidian",               // Obsidian
        "notion.id",                 // Notion
        "org.whispersystems.signal-desktop",
        "com.spotify.client",        // Spotify（CEF）
        "com.microsoft.teams2",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", // Arc
    ]

    /// 同一应用的不同渠道（Beta / Dev / Canary）和通用 Electron 打包 ID
    private static let chromiumBundlePrefixes: [String] = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.chromium.",
        "com.brave.Browser",
        "com.github.Electron",
        "com.electron.",
        "com.microsoft.VSCode",
    ]

    /// 这个 app 是不是 Chromium / Electron 系（只看 bundle ID，不扫 app 包，够便宜）。
    static func isChromiumLike(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if knownChromiumBundleIDs.contains(bundleID) { return true }
        return chromiumBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// 是否已经为这个 app 提示过（每个 app 每次运行只提示一次）。
    @MainActor
    private static var hintedBundleIDs: Set<String> = []

    /// 占位提示资格：第一次拿到 true，之后同一个 app 都是 false。
    @MainActor
    static func claimHint(bundleID: String) -> Bool {
        hintedBundleIDs.insert(bundleID).inserted
    }
}