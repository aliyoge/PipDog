#!/usr/bin/env bash
# 构建 Release 版 PipDog，校验签名，生成 build/dist/PipDog-<版本>.zip 和 .dmg。
#
# 可选环境变量：
#   SIGN_IDENTITY   覆盖签名身份（默认用 Config/Signing.xcconfig 里的 Apple Development）
#   DEVELOPMENT_TEAM 覆盖团队 ID
#   NOTARY_PROFILE  notarytool 钥匙串配置名（xcrun notarytool store-credentials 创建）
# 只有 SIGN_IDENTITY 以 "Developer ID Application" 开头且设置了 NOTARY_PROFILE 时才会公证。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="PipDog"
DERIVED="$ROOT/build"
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

step() { printf '\n==> %s\n' "$*"; }

if command -v xcodegen >/dev/null 2>&1; then
    step "xcodegen generate"
    xcodegen generate --quiet
fi

step "构建 Release"
build_args=(-scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" -destination "generic/platform=macOS")
[[ -n "$SIGN_IDENTITY" ]] && build_args+=("CODE_SIGN_IDENTITY=$SIGN_IDENTITY")
[[ -n "$DEVELOPMENT_TEAM" ]] && build_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
if (( NOTARIZE )); then
    build_args+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
xcodebuild "${build_args[@]}" clean build | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "构建失败：找不到 $APP" >&2; exit 1; }

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
    local staging
    staging="$(mktemp -d "$DERIVED/dmg.XXXXXX")"
    trap 'rm -rf "$staging"' RETURN
    ditto "$APP" "$staging/$APP_NAME.app"
    ln -s /Applications "$staging/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG"
}

step "打包 zip"
make_zip

if (( NOTARIZE )); then
    step "公证 app（可能需要几分钟）"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    make_zip # 重新打包带公证票据的 app
fi

step "打包 dmg"
make_dmg

if (( NOTARIZE )); then
    step "签名并公证 dmg"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

step "完成"
ls -lh "$ZIP" "$DMG"
