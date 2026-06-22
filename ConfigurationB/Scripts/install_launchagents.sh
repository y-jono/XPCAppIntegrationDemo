#!/bin/zsh
set -euo pipefail
CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/$CONFIGURATION"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$DEST"
name="com.example.shared.service"
# テンプレートの __BUILD_PRODUCTS__ を今回のビルド成果物へ置換して登録する。
sed "s#__BUILD_PRODUCTS__#$BUILD_DIR#g" "$ROOT/LaunchAgents/$name.plist" > "$DEST/$name.plist"
launchctl bootout "gui/$(id -u)" "$DEST/$name.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST/$name.plist"
launchctl print "gui/$(id -u)/$name" || true
