# AGENTS.md

- 工程用 XcodeGen 管理：改 `project.yml` 或增删源文件后运行 `xcodegen generate`，不要手改 `PipDog.xcodeproj`。
- 构建验证：`xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build`，提交前必须通过，并且不能有 Swift 警告。
- 只用公开 API；如确需私有 API（SkyLight 等），集中放在单独文件并注明原因。
- 代码与注释可用中文；UI 文案目前为中文。
- 非沙盒 app，最低系统 macOS 14。屏幕录制用于 PiP，辅助功能用于修饰键 + 双击，以及再点一次小窗（默认双击，可改单击）把原窗口移到屏幕边上。
- 权限按需引导，启动不弹框，只读取一次屏幕录制 preflight 快照；不在 PiP 前用 preflight 拦截。抓取成功后相信实际结果（明确 `userDeclined` 时清除成功记录）；否则按当前 preflight 和启动快照区分未授权、已授权、已授权需重启。失败为 `userDeclined`，或尚无成功记录且启动无权限/当前 preflight 为 false 时，走权限引导，其余走通用错误反馈。
- 屏幕录制引导提供重启：`NSWorkspace.openApplication` 设置 `createsNewApplicationInstance = true`，新实例成功启动才退出旧实例，失败用 Feedback。即使 preflight 过时仍可选重启。`CGRequestScreenCaptureAccess` 每次运行最多调用一次，且不和自定义弹窗同时出现：本次运行第一次因未授权导致 PiP 失败时，只调用它并用 Feedback 说明（不弹 NSAlert，因为系统框或 ScreenCaptureKit 自己的框可能正在显示）；之后的失败和菜单点击才弹 NSAlert，点「打开系统设置」时若还没请求过，在弹窗关闭后再请求。macOS 15+ 页面名用「屏幕与系统录音」，macOS 14 用「屏幕录制」。
- 辅助功能引导只用带 prompt 的 `AXIsProcessTrustedWithOptions` 系统框，负责登记到「辅助功能」列表，不再叠加自定义弹窗。设置由关到开且缺权限时引导；已开启时本次运行首次缺权限手势引导，后续手势只用 Feedback。移窗口同理：本次运行第一次因缺权限移不了窗口时调 `Permissions.showAlert(.accessibility, message:)`，之后只 Feedback；启动和切回原窗口从不请求。运行中获得权限并切到 tap 时，用实际修饰键符号提示一次。
- 菜单栏用 AppKit `NSStatusItem` + `NSMenuDelegate.menuNeedsUpdate`（不用 SwiftUI `MenuBarExtra`，它不会在打开时重读非 Observable 的权限状态），每次显示前同步重读权限和设置；设置窗口由 `SettingsActivation.open()` 自己创建（AppKit 菜单里拿不到 `openSettings`）。已授权项禁用，未授权项引导，需重启项确认重启；辅助功能未授权时总是可点（移窗口也需要）。成功抓取记录优先于可能过时的 preflight，因此撤权后的屏幕录制状态可能要等下一次明确拒绝才更新。
- 并发约定（Swift 6 严格并发）：
  - UI、设置和抓取状态都是 `@MainActor`。`WindowCapture` 也是 `@MainActor`，只有 SCStream 的帧回调和停止回调是 `nonisolated`，它们只能碰线程安全的 `FrameMailbox`，再用 `DispatchQueue.main.async` 切回主线程；不要每帧创建 Task。
  - `WindowCapture` 的配置只通过 `setNeedsUpdate()` 串行更新，每次用 `makeConfiguration()` 新建 `SCStreamConfiguration`，不要修改正在更新中的配置对象。输出尺寸以面板像素尺寸为上限（长边 ≤ 4096），面板缩放结束时调用 `PiPPanel.contentSizeDidSettle()`。
  - Carbon 快捷键回调在主 run loop 上执行，用 `MainActor.assumeIsolated`。
  - 修饰键 + 双击的 CGEventTap（`ClickTap`）跑在自己的线程上：回调里只能读写 `ClickTap` 里用锁保护的状态（配置快照、自己窗口的矩形），不能碰主线程对象，要做事就 `DispatchQueue.main.async`。功能关闭时不装 tap；`ClickTrigger` 每秒检查一次辅助功能权限，撤销后拆掉 tap 退回旁观监听。
  - AX 查询（`AXRegionFinder`）不绑定主线程，在后台调用，避免目标 app 卡住时冻结界面。
- PiP 面板只有一条关闭路径：`PiPPanel.close()` → `WindowCapture.stop()`（停止并移除输出）→ `onClose` 从 `PiPManager` 移除。抓取意外结束也走这条路径（`captureEnded` 先关面板；屏幕录制被拒走 `Permissions.showAlert`，其他错误只给中文提示，原始错误写 NSLog）。NSPanel 一定要 `hidesOnDeactivate = false`。
- PiP 面板不用 `isMovableByWindowBackground`：`PiPContentView` 按下后移动 ≥ 4 点才 `performDrag`，否则松开算点击。切回原窗口 / 移到屏幕边上用单击还是双击由 `WindowClickSettings.mode` 决定（UserDefaults `PipDog.windowClickMode`，默认双击，「恢复默认」恢复双击），`mouseUp` 每次实时读取：单击模式每次松开都触发；双击模式只在点击次数为 2、4、6… 时触发（快速连续双击两次会被数成第 4 下）。系统的 `clickCount` 不分修饰键，所以 `mouseUp` 按「是否按着 ⌥」分段计数（`seriesOption` / `seriesStart`）：`clickCount <= 1` 或 ⌥ 状态和上一下不同就从这一下重新数，拖动后清空。⌥ + 单击快速查看两种模式都一样，只认分段后的第 1 下。暂停提示和恢复失败的提示按设置说「单击」或「双击」，改设置时 `PiPManager` 通过 `onModeChange` 更新已打开的小窗。缩放手柄、× 按钮是子视图，事件不经过单击逻辑。× 只调 `PiPPanel.close()`。PiP 平时不能成为 key 窗口（`canBecomeKey` 只在 `allowsKeyFocus` 为 true 时成立，由 `SnapshotPreview` 在快速查看期间设置、关闭后清除），不抢用户的键盘；没有键盘关闭，关单个 PiP 用悬停 ×，关全部用快捷键。
- 画面缩放平移在 `PiPContentView`：滚动（不理惯性阶段）和捏合改 `zoom`（1…8，以鼠标处为中心），`panOffset` 按视图宽高归一化并限制在 `1 - zoom…0`，只改 `imageLayer.frame`（关隐式动画；`setFrameSize` 时重算，所以缩放小窗保持倍数和位置），× / 缩放手柄 / 暂停提示是子视图，不缩放。`zoom > 1` 时超过 4 点的拖动是平移，否则 `performDrag`；两者都算拖动，不算点击、清空连点计数。缩放停下 0.3 秒后 `onZoomSettled` → `PiPPanel.contentSizeDidSettle()`，抓取像素尺寸乘 `zoom`（`WindowCapture` 仍不超过原生分辨率和 4096）。
- 小窗外观（`PiPAppearanceSettings`）：不透明度 UserDefaults `PipDog.windowOpacity`（0.3…1.0，缺省 1.0，不允许 0），悬停自动隐藏 `PipDog.hoverAutoHide`（缺省打开），「恢复默认」恢复两者；`onChange` 由 `PiPManager` 转给各面板的 `appearanceDidChange()`。不透明度用 `alphaValue`。悬停隐藏（`HoverHider`，每个面板一个）：鼠标在面板 frame 里停 0.6 秒后淡到 0 并 `ignoresMouseEvents = true`；进入靠内容视图跟踪区域和本 app 鼠标移动，隐藏后只用全局 + 本 app 的鼠标移动监听和 `NSEvent.mouseLocation` 对比隐藏前的 frame 判断离开（不要靠隐藏引起的 mouseExited，会来回闪），离开后淡回当时设置的不透明度。在面板上按下 / 滚动 / 捏合后本次悬停不再隐藏，直到鼠标离开；计时到时按着鼠标、按着 ⌥、`inLiveResize` 或指着 × / 缩放手柄就再等一轮。隐藏时不改保存的不透明度，隐藏期间改不透明度只在恢复时生效；关掉设置立即恢复；`close()` 里 `stop()` 移除监听和计时器。隐藏 / 恢复发 `HoverHider.clickThroughDidChange`，`ClickTrigger` 据此重读自己窗口的范围（穿透的小窗不算）。
- 单击是切换（`SourceWindowActivator.toggle`）：按当前状态判断，不记单击次数。窗口正在移动（`moving`）→ 忽略；在 `stashed` 里且还在停放的 x（或几乎全在屏幕外）→ `moveBack`：AX 移回原位置，读回确认到位后才删记录，再 `bringToFront`，失败保留记录并 Feedback；没有记录但几乎全在屏幕外 → 拉回所在屏幕可见区域（`onScreenOrigin`），不再停一次；`WindowLocator.onScreenWindows().first?.id` 等于原窗口 → `park`：先写 `stashed`（原位置）再用 AX 设 `kAXPositionAttribute` 移到所在屏幕右边缘外、留 1 点在屏幕内（`parkedOrigin`，全局左上角坐标，y 和大小不变；右边有屏幕改放左边），失败删记录并 Feedback，成功后在 `Stash` 里记下实际移动的 AX 窗口（`AXWindowRef`），之后移回、关闭放回、退出放回都优先用它；`findWindow` 有多个同位置同大小窗口且标题不能唯一区分时返回 nil。`moveWindow` 以 `WindowLocator.bounds(of: windowID)` 的实际位置为准判断成功：先等 0.3 秒，AX 读回已到目标但窗口列表还没跟上时再等到 1 秒（`slowVerifyTimeLimit`）；只有窗口列表里的原窗口确实没动、AX 窗口却动了，才当作移错窗口放回去（`undoOnMismatch`，退出时为 false 不撤回），当作失败；`handFocus` 把前台交给下面的窗口（别的 app 用协作激活，同 app 用 AX 提起，没有就交给访达）；否则走 `bringToFront`。不要用 `hide()`：隐藏 app 会停掉 SCK 抓取，完全移出屏幕有些 app 会停止绘制。PiPManager 在某窗口的最后一个 PiP 关闭时调 `restoreIfStashed`（正在停放就记进 `restoreWhenDone`，等移完再放回；同一窗口又开了 PiP 时 `cancelPendingRestore` 清掉这个标记）；`applicationWillTerminate` 和屏幕录制引导的重启在退出前调 `restoreAllStashed()`，同步移回（不能用 Task）：先关 `parkGate`（之后后台停放不再执行；`parkGate` 里的 `applied` 记着已经发出移动、还没收尾的窗口），有这样的窗口就最多等 1 秒到它出现在停放位置，只移回仍在停放位置的窗口。退出时 HUD 来不及显示，没能移回的只 NSLog，并把提示存进 UserDefaults `PipDog.leftoverParkedWindowsNotice`，下次启动 `showLeftoverNoticeIfNeeded()` 读出、删除并 Feedback。没有辅助功能时单击停放中的窗口只提示，不切前台。不要只看 `app.isActive`：用户在同一 app 的别的窗口里时，单击不隐藏（有辅助功能时提起原窗口；没有时只 Feedback 提示需要辅助功能，不请求权限）。`toggle` 返回原 app 是否已隐藏（移到屏幕边上不算隐藏），`PiPPanel` 据此立即显示 / 去掉暂停提示（`PauseOverlay`，`hitTest` 返回 nil，不挡点击）；另外监听 `NSWorkspace` 的 didHide / didUnhide 通知（⌘H、Dock 等）和 didTerminate（原 app 退出时结束 PiP，隐藏暂停期间也能发现），在 `close()` 里移除。隐藏后 SCK 会停掉流、窗口也可能不在窗口列表里：`WindowCapture` 不能把这当成关闭。流停止或 `bounds(of:)` 为 nil 时走 `sourceMayHaveGone`：app 退出直接 `.windowClosed`；否则先 `pauseUntilShown()`（状态 `.paused`，拆掉流，保留 `lastFrame` 和回调，不调 `onStop`），约 0.6 秒后再判断：`isHidden` 就保持暂停，窗口不见了算关闭，窗口还在但流出错按 `.failed`（屏幕录制被撤销走权限引导），否则重新抓取。取消隐藏（通知或单击）时 `PiPPanel.setSourceHidden(false)` 调 `resumeAfterUnhide()`（返回 true 才去掉暂停提示，false 时保留提示并 Feedback）：用 `shareableWindow(for:)` 重新取 SCWindow（约 1 秒内重试），再走 `start`。`captureEnded` 里原 app 隐藏时也不关面板（保险）。暂停时截图直接用 `lastFrame`。
- 切回原窗口（`SourceWindowActivator.bringToFront`）：原 app `isHidden` 时先 `unhide()`；协作激活：PipDog 不在前台时先 `NSApp.activate()`，再 `NSApp.yieldActivation(to:)` + `activate(from: .current)`（原 app 已在前台且 PipDog 不在前台时跳过）；只有已授权辅助功能时才在后台用 AX 按位置大小匹配（多个匹配时再比 `kCGWindowName` 和 `AXTitle`）并 `AXRaise`，带超时，绝不在这里请求权限。
- 快速查看（`SnapshotPreview`）：从正在运行的 `SCStream` 取原生分辨率截图（`WindowCapture.snapshot()`：最近一帧已是原生尺寸就直接用它；否则等进行中的配置更新结束，临时把流切到原生分辨率，等下一帧该尺寸的完整帧，用 Core Image 复制成 CGImage，再用 `makeConfiguration()` 恢复；1.5 秒超时时退回 `lastFrame`（没有才报错），抓取停止会结束等待；同时只截一张。不要用 `SCScreenshotManager` 或另开 SCStream，同一窗口第二个会话会失败）→ `NSTemporaryDirectory()/PipDog` 里的 PNG（替换时删旧文件，启动和退出时删目录）→ `QLPreviewPanel`。控制者是 PiP 面板（`canBecomeMain = true`，打开时临时 `allowsKeyFocus = true`，快速查看从 key / 主窗口的响应链找控制者；快速查看真正关闭后清除，此时 Esc 只关快速查看）；⌥ + 单击时 `prepare` 就开始激活 PipDog（和截图同时进行）。收尾统一走 `restoreIfClosed()`（快速查看不可见时才动作，可重复调用）：`endPreviewPanelControl`、打开后 0.5 秒检查、PipDog 失去前台、截图失败都会调用；它清掉 `allowsKeyFocus`，把前台还给之前的 app，没有可还的 app 时让出 key（交给设置窗口或 `NSApp.deactivate()`）。PNG 在后台编码，写文件的错误都包成 `WriteError`。不加键盘监听。
- 开机时启动（`LaunchAtLogin`）：只用 `SMAppService.mainApp` 的 `register()` / `unregister()`，以 `status` 为准（`.enabled` 或 `.requiresApproval` 算已打开），不存 UserDefaults，不用辅助 app、`SMLoginItemSetEnabled` 或 AppleScript。启动时不登记、不提示；`.requiresApproval` 时提示去「系统设置 › 通用 › 登录项与扩展」（设置窗口给按钮，菜单直接 `openSystemSettingsLoginItems()`）；`.notFound` 提示先装到「应用程序」。「恢复默认」不动它。PipDog 变成前台、`SettingsActivation.open()`、设置窗口出现、菜单打开时重新读状态；`setEnabled` 先刷新，状态已经对了就不动，出错后再刷新一次，已达到目标就不提示；系统错误换成中文提示（只对 `SMAppServiceErrorDomain` / `kSMErrorDomainFramework` 域按错误码说明，其他域用通用说明），原文只写 NSLog。
- 给用户的错误反馈用 `Feedback.show(...)`（提示浮层）；缺权限用 `Permissions.showAlert(...)`。不要只写 NSLog。
- 签名配置在 `Config/Signing.xcconfig`，不要在 `project.yml` 里写签名设置；本机覆盖用未跟踪的 `Config/Signing.local.xcconfig`。开启了 Hardened Runtime，新增需要特殊权限的能力（Apple Events、JIT 等）时要补 entitlements。
- 打包用 `./scripts/package.sh`，产物在 `build/dist/`（不提交），完整日志在 `build/xcodebuild.log`。脚本不能输出任何密钥，公证凭据只用 notarytool 钥匙串配置。
- 换图标：替换 `Design/AppIcon-1024.png` 后按 README 用 `sips` 重新生成 `AppIcon.appiconset`。

## Git 提交规范

- 标题和正文使用中文；代码标识符、路径等专有名词保持原文，用反引号包裹。
- 标题为祈使句式短句，不加句号，不超过 50 个汉字；空一行后写正文，说明目的、影响和必要的兼容策略，不逐文件复述 diff。
- 多主题提交用 `1.`、`2.` 分组，各组总结以中文冒号结尾；组内要点使用三个空格加 `- ` 缩进，续行与正文对齐。
- 涉及持久化、协议或跨服务字段时，说明旧数据、缺失字段及升级兼容方式；涉及界面时，正文末尾说明用户能看到的变化和入口。
- 不加入无关改动、临时调试产物或凭据，不用“最终版”“按要求修改”等无信息量描述。

模板按需裁剪：

```text
<中文祈使句标题>

<为什么改、影响什么>

1. <第一组改动>：
   - <关键行为与兼容说明>

2. <第二组改动>：
   - <关键行为与影响>

<用户可见变化及入口，无界面变化时省略>
```
