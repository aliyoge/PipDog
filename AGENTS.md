# AGENTS.md

- 工程用 XcodeGen 管理：改 `project.yml` 或增删源文件后运行 `xcodegen generate`，不要手改 `PipDog.xcodeproj`。
- 构建验证：`xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build`，提交前必须通过，并且不能有 Swift 警告。
- 只用公开 API；如确需私有 API（SkyLight 等），集中放在单独文件并注明原因。
- 代码与注释可用中文；UI 文案目前为中文。
- 非沙盒 app（需要辅助功能和屏幕录制），最低系统 macOS 14。
- 并发约定（Swift 6 严格并发）：
  - UI、设置和抓取状态都是 `@MainActor`。`WindowCapture` 也是 `@MainActor`，只有 SCStream 的帧回调和停止回调是 `nonisolated`，它们只能碰线程安全的 `FrameMailbox`，再用 `DispatchQueue.main.async` 切回主线程；不要每帧创建 Task。
  - `WindowCapture` 的配置只通过 `setNeedsUpdate()` 串行更新，每次用 `makeConfiguration()` 新建 `SCStreamConfiguration`，不要修改正在更新中的配置对象。输出尺寸以面板像素尺寸为上限（长边 ≤ 4096），面板缩放结束时调用 `PiPPanel.contentSizeDidSettle()`。
  - Carbon 快捷键回调在主 run loop 上执行，用 `MainActor.assumeIsolated`。
  - 修饰键 + 双击的 CGEventTap（`ClickTap`）跑在自己的线程上：回调里只能读写 `ClickTap` 里用锁保护的状态（配置快照、自己窗口的矩形），不能碰主线程对象，要做事就 `DispatchQueue.main.async`。功能关闭时不装 tap；`ClickTrigger` 每秒检查一次辅助功能权限，撤销后拆掉 tap 退回旁观监听。
  - AX 查询（`AXRegionFinder`）不绑定主线程，在后台调用，避免目标 app 卡住时冻结界面。
- PiP 面板只有一条关闭路径：`PiPPanel.close()` → `WindowCapture.stop()`（停止并移除输出）→ `onClose` 从 `PiPManager` 移除。抓取意外结束也走这条路径。NSPanel 一定要 `hidesOnDeactivate = false`。
- 给用户的错误反馈用 `Feedback.show(...)`（提示浮层）；缺权限用 `Permissions.showAlert(...)`。不要只写 NSLog。
- 签名配置在 `Config/Signing.xcconfig`，不要在 `project.yml` 里写签名设置；本机覆盖用未跟踪的 `Config/Signing.local.xcconfig`。开启了 Hardened Runtime，新增需要特殊权限的能力（Apple Events、JIT 等）时要补 entitlements。
- 打包用 `./scripts/package.sh`，产物在 `build/dist/`（不提交），完整日志在 `build/xcodebuild.log`。脚本不能输出任何密钥，公证凭据只用 notarytool 钥匙串配置。
- 换图标：替换 `Design/AppIcon-1024.png` 后按 README 用 `sips` 重新生成 `AppIcon.appiconset`。
