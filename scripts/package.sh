#!/usr/bin/env bash
# 构建 Release 版 PipDog，校验签名，生成 build/dist/PipDog-<版本>.zip 和 .dmg。
#
# 可选环境变量：
#   SIGN_IDENTITY    覆盖签名身份（默认用 Config/Signing.xcconfig 里的 Apple Development）
#   DEVELOPMENT_TEAM 覆盖团队 ID
#   NOTARY_PROFILE   notarytool 钥匙串配置名（xcrun notarytool store-credentials 创建）
# 只有 SIGN_IDENTITY 以 "Developer ID Application" 开头且设置了 NOTARY_PROFILE 时才会公证。
#
# 副作用：装了 xcodegen 时会先运行 `xcodegen generate`，如果 project.yml 和已提交的
# PipDog.xcodeproj 不一致，会改动 PipDog.xcodeproj（git status 里能看到）。
# 完整构建日志在 build/xcodebuild.log。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="PipDog"
DERIVED="$ROOT/build"
LOG="$DERIVED/xcodebuild.log"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="$DERIVED/dist"
ENTITLEMENTS="$ROOT/PipDog/Resources/PipDog.entitlements"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

NOTARIZE=0
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* && -n "$NOTARY_PROFILE" ]]; then
    NOTARIZE=1
fi

STAGING=""
cleanup() {
    if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "错误：$*" >&2; exit 1; }

if command -v xcodegen >/dev/null 2>&1; then
    step "xcodegen generate"
    xcodegen generate --quiet
fi

step "构建 Release（完整日志：${LOG}）"
mkdir -p "$DERIVED"
build_args=(-scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" -destination "generic/platform=macOS")
if [[ -n "$SIGN_IDENTITY" ]]; then build_args+=("CODE_SIGN_IDENTITY=$SIGN_IDENTITY"); fi
if [[ -n "$DEVELOPMENT_TEAM" ]]; then build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi
if (( NOTARIZE )); then build_args+=("OTHER_CODE_SIGN_FLAGS=--timestamp"); fi
if ! xcodebuild "${build_args[@]}" clean build >"$LOG" 2>&1; then
    echo "构建失败，日志最后 40 行：" >&2
    tail -n 40 "$LOG" >&2
    exit 1
fi
# 打印 Swift 警告（去重），没有就什么也不输出
grep -E "\.swift:[0-9]+:[0-9]+: warning:" "$LOG" | sort -u || true
echo "BUILD SUCCEEDED"
[[ -d "$APP" ]] || fail "构建成功但找不到 $APP"

if (( NOTARIZE )); then
    step "用 Developer ID 重新签名（hardened runtime + 时间戳）"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
fi

step "校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Format|Authority|TeamIdentifier|Timestamp|Runtime Version)|flags=" || true

step "Gatekeeper 评估（没有 Developer ID 公证时会被拒绝，属正常）"
spctl -a -vv "$APP" 2>&1 || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -rf "$DIST"
mkdir -p "$DIST"

make_zip() {
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
}

make_dmg() {
    STAGING="$(mktemp -d "$DERIVED/dmg.XXXXXX")"
    ditto "$APP" "$STAGING/$APP_NAME.app"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    rm -rf "$STAGING"
    STAGING=""
}

# 提交公证并等待结果；状态不是 Accepted 时打印公证日志并退出。
# （notarytool submit --wait 在状态为 Invalid 时也可能返回 0，所以要自己检查 status。）
notarize() {
    local file="$1" result status id
    step "公证 $(basename "$file")（可能需要几分钟）"
    if ! result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"; then
        fail "notarytool submit 失败：$result"
    fi
    status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo "unknown")"
    id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || echo "")"
    echo "公证状态：${status}（submission id：${id:-未知}）"
    if [[ "$status" != "Accepted" ]]; then
        if [[ -n "$id" ]]; then
            echo "公证日志：" >&2
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        fail "公证没有通过（${status}）"
    fi
}

step "打包 zip"
make_zip

if (( NOTARIZE )); then
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    make_zip # 重新打包带公证票据的 app
fi

step "打包 dmg"
make_dmg

if (( NOTARIZE )); then
    step "签名 dmg"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

step "完成"
ls -lh "$ZIP" "$DMG"
