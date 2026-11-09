# PipDog

一个 macOS 菜单栏小工具：把任意窗口变成置顶、跨 Space 的画中画（PiP）浮窗。灵感来自 Pipiri。

## 技术栈
- Swift 6 + SwiftUI（菜单栏）+ AppKit（NSPanel 浮窗）
- ScreenCaptureKit 实时抓取窗口画面
- Carbon `RegisterEventHotKey` 全局快捷键（不需要额外权限）
- 辅助功能（Accessibility）接口：修饰键 + 双击时找鼠标下方的界面元素
- 只用公开 API（CGWindowList、ScreenCaptureKit、AXUIElement）
- 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，`.xcodeproj` 不手改

## 开发
```sh
xcodegen generate          # 改了 project.yml 或增删文件后重新生成
open PipDog.xcodeproj      # 或命令行构建：
xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/PipDog.app
```
首次运行需在「系统设置 › 隐私与安全性」里授予 **屏幕录制** 和 **辅助功能** 权限。
当前是本地临时签名（ad-hoc），每次重新构建后系统可能要求重新授权；以后可换成自己的开发者证书签名。

## 使用
| 快捷键 | 作用 |
| --- | --- |
| ⌃⌥P | PiP 当前聚焦的整个窗口 |
| ⌃⌥⇧P | 框选区域 PiP |
| ⌃⌥ + 双击 | PiP 鼠标下方的区域（如日志面板、聊天框） |
| ⌃⌥⌫ | 关闭所有 PiP |
| Esc / ⌫（PiP 小窗聚焦时） | 关闭这个 PiP |

- 可以同时开多个 PiP，新小窗会错开摆放；对同一个窗口或同一块区域再次触发，只会把已有小窗提到前面。
- **框选区域**：按 ⌃⌥⇧P 后所有屏幕变暗，拖出一个矩形（小于 20 点的忽略），松开即 PiP；Esc 取消。PiP 的是选区中心下方最上层的那个窗口，选区超出窗口的部分会被裁掉。之后即使原窗口被挡住或移动，小窗显示的仍是该窗口里的同一块区域。
- **⌃⌥ + 双击**：用辅助功能接口找到鼠标下方合适的容器（滚动区、文本区、网页、表格、列表等，至少 120×60 且不是几乎整个窗口）；找不到时取以点击处为中心的 480×300 区域。需要辅助功能权限，没授权时会弹系统提示。
- 菜单栏里的菜单项同样可以触发这些功能。

## 目录
- `PipDog/App`：入口、菜单栏、权限、快捷键注册
- `PipDog/PiP`：PiP 管理、浮窗面板、窗口抓取（支持区域 `sourceRect`）
- `PipDog/Input`：全局快捷键、框选遮罩、修饰键 + 双击、AX 元素查找
- `PipDog/Support`：坐标系换算（左上角 ↔ 左下角原点）、窗口定位

## 路线图
- [x] 菜单栏 app、PiP 当前窗口（实时画面、置顶、跨 Space、Esc/⌫ 关闭）
- [x] 全局快捷键、同时多个 PiP
- [x] 区域 PiP：框选、修饰键 + 双击
- [ ] 快捷键和触发修饰键可在设置里修改
- [ ] 点击 PiP 回到原窗口
- [ ] 缩放/平移、透明度、悬停自动隐藏
- [ ] 空闲/变化检测与通知、触发脚本
- [ ] 媒体控制
- [ ] 设置界面、开机自启
