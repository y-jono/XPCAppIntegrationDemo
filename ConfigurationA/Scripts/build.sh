#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
cd "$(dirname "$0")/.."
# DerivedData はリポジトリ内に固定し、権限差でビルドが壊れないようにする。
xcodebuild -project XPCAppIntegrationA.xcodeproj -scheme AppA -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" build
xcodebuild -project XPCAppIntegrationA.xcodeproj -scheme AppB -configuration "$CONFIGURATION" -derivedDataPath "$PWD/DerivedData" build
for app in AppA AppB; do
  test -d "$PWD/build/$CONFIGURATION/$app.app"
  test -x "$PWD/build/$CONFIGURATION/$app.app/Contents/MacOS/$app"
  test "$(plutil -extract CFBundlePackageType raw "$PWD/build/$CONFIGURATION/$app.app/Contents/Info.plist")" = "APPL"
done
