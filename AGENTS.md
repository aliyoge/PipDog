# AGENTS.md

- 工程用 XcodeGen 管理：改 `project.yml` 或增删源文件后运行 `xcodegen generate`，不要手改 `PipDog.xcodeproj`。
- 构建验证：`xcodebuild -scheme PipDog -configuration Debug -derivedDataPath build build`，提交前必须通过。
- 只用公开 API；如确需私有 API（SkyLight 等），集中放在单独文件并注明原因。
- 代码与注释可用中文；UI 文案目前为中文。
- 非沙盒 app（需要辅助功能和屏幕录制），最低系统 macOS 14。
- 签名配置在 `Config/Signing.xcconfig`，不要在 `project.yml` 里写签名设置；本机覆盖用未跟踪的 `Config/Signing.local.xcconfig`。开启了 Hardened Runtime，新增需要特殊权限的能力（Apple Events、JIT 等）时要补 entitlements。
- 打包用 `./scripts/package.sh`，产物在 `build/dist/`（不提交）。脚本不能输出任何密钥，公证凭据只用 notarytool 钥匙串配置。
- 换图标：替换 `Design/AppIcon-1024.png` 后按 README 用 `sips` 重新生成 `AppIcon.appiconset`。
