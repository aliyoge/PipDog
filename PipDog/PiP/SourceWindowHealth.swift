import Foundation

/// 源窗口此刻的健康状况：决定抓取意外结束后是「等源 app 重启后重连」还是「照常结束」。
///
/// 只回答 PiP 需要的三种情况。判断用的两个事实由调用方查好
/// （`NSRunningApplication` 是否还在、`CGWindowList` 里还有没有这个窗口 ID），
/// 这里只做策略，方便单独核对：app 退出 → 重连；app 还在但窗口没了 → 结束；
/// 都在 → 继续（隐藏、最小化由暂停提示处理，不在这里判断）。
enum SourceWindowHealth: Equatable {
    /// app 和窗口都还在
    case alive
    /// app 已经退出：小窗不关，等它重启后重连
    case appQuit
    /// app 还活着，但那个窗口已经关了：照常结束
    case windowGone

    static func classify(appIsRunning: Bool, windowIsListed: Bool) -> SourceWindowHealth {
        guard appIsRunning else { return .appQuit }
        return windowIsListed ? .alive : .windowGone
    }
}