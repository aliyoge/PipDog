# AGENTS.md

- 工程用 XcodeGen 管理：改 `project.yml` 或增删源文件后运行 `xcodegen generate`，不要手改 `PipDog.xcodeproj`。
- 构建验证：`xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build`，提交前必须通过。
- 只用公开 API；如确需私有 API（SkyLight 等），集中放在单独文件并注明原因。
- 代码与注释可用中文；UI 文案目前为中文。
- 非沙盒 app（需要辅助功能和屏幕录制），最低系统 macOS 14。
