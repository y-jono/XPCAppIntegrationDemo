#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
cd "$(dirname "$0")/.."
# DerivedData はリポジトリ内に固定し、権限差でビルドが壊れないようにする。
EXTRA_BUILD_SETTINGS=()
if [[ "${BUILD_USE_CORRECT_REQUIREMENT:-0}" == "1" ]]; then
  if [[ "$CONFIGURATION" == "Debug" ]]; then
    EXTRA_BUILD_SETTINGS+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG USE_CORRECT_REQUIREMENT")
  else
    EXTRA_BUILD_SETTINGS+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="USE_CORRECT_REQUIREMENT")
  fi
fi
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme AppA -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" "${EXTRA_BUILD_SETTINGS[@]}" build
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme AppB -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" "${EXTRA_BUILD_SETTINGS[@]}" build
xcodebuild -project XPCAppIntegrationB.xcodeproj -scheme SharedService -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" "${EXTRA_BUILD_SETTINGS[@]}" build
for app in AppA AppB SharedService; do
  test -d "$PWD/build/$CONFIGURATION/$app.app"
  test -x "$PWD/build/$CONFIGURATION/$app.app/Contents/MacOS/$app"
  test "$(plutil -extract CFBundlePackageType raw "$PWD/build/$CONFIGURATION/$app.app/Contents/Info.plist")" = "APPL"
done
