# PipDog

一个 macOS 菜单栏小工具：把任意窗口变成置顶、跨 Space 的画中画（PiP）浮窗。灵感来自 Pipiri。

## 技术栈
- Swift 6 + SwiftUI（设置）+ AppKit（菜单栏、NSPanel 浮窗）
- ScreenCaptureKit 实时抓取窗口画面
- Carbon `RegisterEventHotKey` 全局快捷键（不需要额外权限）
- CGEventTap（跑在独立线程上，不受主线程卡顿影响）：修饰键 + 双击触发，并拦截触发用的那次点击（需要辅助功能权限）
- 辅助功能（Accessibility）接口：修饰键 + 双击时找鼠标下方的界面元素；单击 PiP 切回原窗口时（有权限才用）把那个窗口提到最前
- `SCScreenshotManager` + Quick Look（`QLPreviewPanel`）：⌥ + 单击 PiP 看原尺寸截图
- 只用公开 API（CGWindowList、ScreenCaptureKit、AXUIElement、CGEventTap、QuickLookUI）
- 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，`.xcodeproj` 不手改

## 开发
```sh
xcodegen generate          # 改了 project.yml 或增删文件后重新生成
open PipDog.xcodeproj      # 或命令行构建：
xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/PipDog.app
```
启动时不弹任何授权框，权限都是用到时才引导：

- **屏幕录制**（macOS 15+ 叫「屏幕与系统录音」）：PiP 时总是直接尝试抓取。本次运行第一次因没权限失败时，PipDog 让系统弹出授权框（同时把 PipDog 登记到系统设置的列表里），并在屏幕顶部提示去哪里打开；之后再失败会弹出说明框，带「打开系统设置」「重新启动 PipDog」「取消」。运行中授权后要重新启动 PipDog 才生效，这时说明框会直接提示「已授权，需要重新启动」。即使系统暂时仍显示未授权（macOS 15 偶尔如此），也可以直接点「重新启动 PipDog」。重启先启动新实例，成功后才退出旧的；失败只提示，不退出。
- **辅助功能**：只有修饰键 + 双击需要（单击 PiP 切回原窗口时有权限就顺便用来提起具体窗口，没有也不会弹框）。在设置里打开这个功能而缺权限时，或功能已开启、本次运行第一次做这个手势时，弹出系统的辅助功能授权框；之后的手势只显示简短提示。功能关闭时不要求辅助功能。运行中授权后会自动生效并提示一次。
- **菜单**里显示两项权限的当前状态（每次打开菜单都会重新读取）：屏幕录制「已授权 / 未授权 / 已授权，需重新启动」，辅助功能「已授权 / 未授权」（双击关闭时显示「不需要」）。点未授权的项会弹出对应引导，点「需重新启动」会确认后重启。屏幕录制在本次运行成功抓取过以后就显示已授权；如果运行中撤销了权限，要等下一次 PiP 失败后才会变回未授权。

现在用固定的开发者证书签名，重新构建后这些权限一般会保留（之前签过 ad-hoc 版的话，可能需要在权限列表里删掉旧条目重新授权一次）。

## 应用图标
- 原图在 `Design/AppIcon-1024.png`（1024×1024 透明 PNG，图标主体约 824×824，符合 macOS 图标网格）。
- `PipDog/Resources/Assets.xcassets/AppIcon.appiconset` 里是各尺寸（16–512 的 @1x/@2x）。换图标时替换原图后重新生成：
  ```sh
  cd PipDog/Resources/Assets.xcassets/AppIcon.appiconset
  for s in 16 32 128 256 512; do
    sips -z $s $s ../../../../Design/AppIcon-1024.png --out icon_${s}x${s}.png
    sips -z $((s*2)) $((s*2)) ../../../../Design/AppIcon-1024.png --out icon_${s}x${s}@2x.png
  done
  ```
- 菜单栏图标仍是 SF Symbol `pip`。

## 签名
- 默认值在 `Config/Signing.xcconfig`（已提交）：`Apple Development` 证书、团队 `653QLVW4RT`、手动签名、开启 Hardened Runtime、非沙盒。Release 不带 `get-task-allow`。
- 本机想换证书或团队时，新建未跟踪的 `Config/Signing.local.xcconfig` 覆盖即可（已在 `.gitignore`），例如：
  ```
  CODE_SIGN_IDENTITY = Developer ID Application
  DEVELOPMENT_TEAM = XXXXXXXXXX
  ```
- 查看本机可用证书：`security find-identity -v -p codesigning`。

## 打包
```sh
./scripts/package.sh
```
会构建 Release（通用二进制 arm64 + x86_64），校验签名（`codesign --verify --deep --strict`），打印 Gatekeeper 评估（`spctl`），并生成：
- `build/dist/PipDog-<版本>.zip`
- `build/dist/PipDog-<版本>.dmg`（里面有拖到 Applications 的快捷方式）

注意：
- 完整构建日志写在 `build/xcodebuild.log`；构建失败时脚本会打印日志最后 40 行并退出。
- 装了 xcodegen 时脚本会先运行 `xcodegen generate`。如果 `project.yml` 和已提交的 `PipDog.xcodeproj` 不一致，这一步会改动工程文件（`git status` 里能看到）。

版本号取 `project.yml` 里的 `MARKETING_VERSION`。

用 Apple Development 证书签的包 **没有公证**：`spctl` 会显示 rejected，这是正常的。在自己的 Mac 上可以直接用；发给别人时对方需要右键 › 打开，或在「隐私与安全性」里点「仍要打开」。

### 以后换成 Developer ID 并公证
1. 在 Apple 开发者账号里创建 **Developer ID Application** 证书并装进钥匙串。
2. 保存公证凭据（只需一次，密码会存进钥匙串，不会写进仓库）：
   ```sh
   xcrun notarytool store-credentials pipdog-notary --apple-id <Apple ID> --team-id <团队 ID>
   ```
3. 打包时指定身份和凭据名：
   ```sh
   SIGN_IDENTITY="Developer ID Application: 名字 (团队 ID)" NOTARY_PROFILE=pipdog-notary ./scripts/package.sh
   ```
   脚本会用 hardened runtime 加时间戳重新签名，用 `notarytool submit --wait --output-format json` 提交 app 和 dmg 去公证，并检查返回的状态：不是 `Accepted` 就打印 `notarytool log` 的内容并退出；通过后用 `stapler staple` 把票据装订进去。也可以在 `Signing.local.xcconfig` 里改默认身份。

## 使用
以下是默认快捷键，都可以在「设置…」（菜单栏 › 设置…，⌘,）里修改：

| 快捷键 | 作用 |
| --- | --- |
| ⌃⌥P | PiP 当前聚焦的整个窗口 |
| ⌃⌥⇧P | 框选区域 PiP |
| ⌥⇧ + 双击 | PiP 鼠标下方的区域（如日志面板、聊天框） |
| ⌃⌥⌫ | 关闭所有 PiP |
| 单击小窗 | 切回原窗口 |
| ⌥ + 单击小窗 | 用快速查看看原尺寸截图 |
| 小窗左上角 ×（鼠标移上去才显示） | 关闭这个 PiP |
| Esc / ⌫（PiP 小窗聚焦时，例如刚拖动过） | 关闭这个 PiP |

- 可以同时开多个 PiP，新小窗会错开摆放，并出现在原窗口所在的屏幕上（找不到时用鼠标所在的屏幕）。对同一个窗口或同一块区域再次触发，只会把已有小窗提到前面。
- **PiP 当前窗口**：PiP 的是最前面那个 app 的窗口。如果最前面的 app 没有可以 PiP 的窗口，只会提示，不会去抓别的 app 的窗口。
- **框选区域**：按 ⌃⌥⇧P 后所有屏幕变暗，拖出一个矩形（小于 20 点的忽略），松开即 PiP；按 Esc、点右键、再按一次框选快捷键，或切到别的 app 都会取消。PiP 的是选区中心下方最上层的那个窗口，选区超出窗口的部分会被裁掉。之后即使原窗口被挡住或移动，小窗显示的仍是该窗口里的同一块区域。
- **⌥⇧ + 双击**：用辅助功能接口找到鼠标下方合适的容器（滚动区、文本区、网页、表格、列表等，至少 120×60 且不是几乎整个窗口）；找不到时取以点击处为中心的 480×300 区域。触发用的第二次点击会被 PipDog 拦下，不会传给目标 app（第一次单击仍会照常传过去）。需要辅助功能权限；没授权时只能旁观、双击仍会传给目标 app，本次运行首次手势用系统授权框引导，后续只显示提示。授权后约 1 秒内自动切换成拦截模式，并提示一次；运行中撤销权限会自动退回旁观模式。在设置里关掉这个功能后，PipDog 完全不再监听鼠标。
- **单击小窗**：激活原窗口所在的 app。有辅助功能权限时，再把原窗口本身提到最前（按原窗口当前的位置和大小在该 app 的窗口里找，误差 2 点以内；查询在后台进行，最多约 0.5 秒）；没有权限、原窗口已最小化或没找到时，只激活 app，不弹任何授权框。按下后移动不到 4 点就松开才算单击，超过就是拖动小窗，不会切走；拖缩放手柄、点 × 也不算单击。连续双击只按第一次单击处理。
- **⌥ + 单击小窗**：给原窗口拍一张原生分辨率的截图（区域 PiP 只截那块区域，不受小窗大小和 4096 上限影响），存成 PNG 放在临时目录 `$TMPDIR/PipDog`，用快速查看打开。打开前 PipDog 会临时切到前台；按空格或 Esc 关闭快速查看后，如果 PipDog 还在前台，就把前台还给之前的 app。快速查看开着时 ⌥ + 单击另一个小窗会换成那张截图。新截图会删掉上一张，退出 PipDog 时删掉整个目录。截图失败（例如原窗口已不可见、没有屏幕录制权限）时在屏幕顶部提示原因。
- **关闭单个小窗**：鼠标移到小窗上时左上角出现 ×，点它只关这一个；移开后 × 隐藏。
- **小窗**：拖动画面移动；拖右下角的手柄等比缩放（不会拖出屏幕可见区域）。抓取分辨率跟着小窗的像素尺寸走（长边最多 4096），不按原窗口的原生分辨率抓，省内存和 CPU；放大小窗松手后画面会变清晰。原窗口改变大小或移到缩放比例不同的屏幕时，画面和小窗的宽高比会自动跟着调整；区域 PiP 在原窗口变小时会裁剪到窗口内，窗口变回来后恢复原区域。原窗口关闭后小窗会自动关闭并提示（即使画面静止，也会在约 1.5 秒内发现）。
- 出错（找不到窗口、区域太小、抓取失败等）时，屏幕顶部会出现一个几秒后自动消失的提示。
- 菜单栏里的菜单项同样可以触发这些功能，菜单上显示的是当前生效的快捷键。

### 设置
- **全局快捷键**：点击某个动作右边的按钮开始录制，按下新的组合键即可，立即生效、无需重启。组合键至少要包含 ⌘、⌃ 或 ⌥（只有 ⇧ 不行），并且不能只用 ⌘ 或 ⌘⇧ 加普通按键（会抢走 ⌘C、⌘Q、⌘W 这类常用快捷键；F1–F20 除外）；录制时按 Esc 取消，切到别的 app 或设置窗口失去焦点也会自动取消；点 × 清除，清除后该动作没有快捷键，但仍可从菜单使用。录制期间全局快捷键会暂停，所以可以重新录当前的组合。
- **冲突**：同一个组合不能分配给两个动作；如果组合已被其他 app 注册，会在那一行下面显示红字并保留原来的快捷键；如果是全局快捷键功能本身初始化失败，红字会说明错误码，这时只能从菜单使用。被系统自己占用的组合（如 ⌘ 空格）检测不出来。
- **修饰键 + 双击**：可以开关，也可以选择需要按住哪些修饰键（⌃ ⌥ ⇧ ⌘，至少一个）。默认 ⌥⇧（旧版本默认是 ⌃⌥；已经保存过设置的用户保持原来的设置不变）。按住 ⌃ 点击时 macOS 会把第一次点击当成右键，所以不推荐包含 ⌃。
- **帧率**：PiP 画面每秒刷新次数，可选 5 / 10 / 15 / 24 / 30 / 60 fps，默认 10。修改后立即应用到已打开的 PiP。帧率越高越流畅，CPU 占用也越高。
- **恢复默认**：恢复上面表格里的默认快捷键、双击设置和帧率（10 fps）。
- 设置保存在 UserDefaults（`com.hwj.PipDog` 的 `PipDog.shortcutConfig` 和 `PipDog.captureFrameRate`），启动时读取；没有保存过时用默认值。读取是宽容的：缺少的字段用默认值，单个坏掉的快捷键（或不带修饰键的快捷键）只丢掉那一项。
- 设置窗口打开期间 PipDog 会临时显示 Dock 图标，这样窗口能稳定地出现在最前面；关闭设置窗口后 Dock 图标消失。

## 目录
- `Config`：签名配置（xcconfig）
- `Design`：图标原图
- `scripts`：打包脚本
- `PipDog/App`：入口、菜单栏、权限检查和提示
- `PipDog/PiP`：PiP 管理、浮窗面板和内容视图（单击 / 拖动、悬停 ×）、缩放手柄、窗口抓取（支持区域 `sourceRect`、跟随窗口尺寸）、切回原窗口、快速查看截图
- `PipDog/Settings`：快捷键设置（存储、注册、录制）、设置界面和设置窗口激活
- `PipDog/Input`：全局快捷键、框选遮罩、修饰键 + 双击（CGEventTap）、AX 元素查找
- `PipDog/Support`：坐标系换算（左上角 ↔ 左下角原点）、窗口定位、提示浮层

## 路线图
- [x] 菜单栏 app、PiP 当前窗口（实时画面、置顶、跨 Space、Esc/⌫ 关闭）
- [x] 可调帧率（默认 10 fps，实时生效）
- [x] 全局快捷键、同时多个 PiP
- [x] 区域 PiP：框选、修饰键 + 双击
- [x] 设置界面：自定义快捷键、双击触发修饰键
- [x] 跟随原窗口尺寸、原窗口关闭时自动关闭、错误提示
- [x] 点击 PiP 回到原窗口、⌥ + 单击快速查看原尺寸、悬停 × 关闭
- [ ] 平移、透明度、悬停自动隐藏
- [ ] 空闲/变化检测与通知、触发脚本
- [ ] 媒体控制
- [x] 应用图标、固定签名、打包 zip/dmg（可选公证）
- [ ] 开机自启
