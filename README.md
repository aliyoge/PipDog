# PipDog

一个 macOS 菜单栏小工具：把任意窗口变成置顶、跨 Space 的画中画（PiP）浮窗。灵感来自 Pipiri。

## 技术栈
- Swift 6 + SwiftUI（菜单栏）+ AppKit（NSPanel 浮窗）
- ScreenCaptureKit 实时抓取窗口画面
- 辅助功能（Accessibility）接口，用于后续的窗口操作、全局快捷键
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

## 目录
- `PipDog/App`：入口、菜单栏、权限
- `PipDog/PiP`：PiP 管理、浮窗面板、窗口抓取

## 路线图
- [x] 菜单栏 app、PiP 当前窗口（实时画面、置顶、跨 Space、Esc/⌫ 关闭）
- [ ] 全局快捷键、区域选择 PiP
- [ ] 点击 PiP 回到原窗口
- [ ] 缩放/平移、透明度、悬停自动隐藏
- [ ] 空闲/变化检测与通知、触发脚本
- [ ] 媒体控制
- [ ] 设置界面、开机自启
