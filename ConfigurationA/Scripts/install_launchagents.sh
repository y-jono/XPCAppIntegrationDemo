#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/$CONFIGURATION"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$DEST"
# テンプレートの __BUILD_PRODUCTS__ を今回のビルド成果物へ置換して登録する。
for name in com.example.appA.service com.example.appB.service; do
  sed "s#__BUILD_PRODUCTS__#$BUILD_DIR#g" "$ROOT/LaunchAgents/$name.plist" > "$DEST/$name.plist"
  launchctl bootout "gui/$(id -u)" "$DEST/$name.plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$DEST/$name.plist"
done
launchctl print "gui/$(id -u)/com.example.appA.service" || true
launchctl print "gui/$(id -u)/com.example.appB.service" || true
