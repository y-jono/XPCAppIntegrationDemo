#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
cd "$(dirname "$0")/.."
# Release 用: 環境変数 DEVELOPMENT_TEAM を設定すると、pbxproj を書き換えずに
# Team ID を上書きできる（例: DEVELOPMENT_TEAM=ABCDE12345 build.sh Release）。
# 未設定なら pbxproj の値（プレースホルダ EXAMPLE123）がそのまま使われる。
typeset -a extra_settings
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  extra_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
# DerivedData はリポジトリ内に固定し、権限差でビルドが壊れないようにする。
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme AppA -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" build "${extra_settings[@]}"
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme AppB -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" build "${extra_settings[@]}"
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme SharedService -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" build "${extra_settings[@]}"
for app in AppA AppB SharedService; do
  test -d "$PWD/build/$CONFIGURATION/$app.app"
  test -x "$PWD/build/$CONFIGURATION/$app.app/Contents/MacOS/$app"
  test "$(plutil -extract CFBundlePackageType raw "$PWD/build/$CONFIGURATION/$app.app/Contents/Info.plist")" = "APPL"
done
