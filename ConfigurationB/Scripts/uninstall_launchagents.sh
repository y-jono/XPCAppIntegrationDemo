#!/bin/zsh
set -euo pipefail
DEST="$HOME/Library/LaunchAgents"
name="com.example.shared.service"
launchctl bootout "gui/$(id -u)" "$DEST/$name.plist" 2>/dev/null || true
rm -f "$DEST/$name.plist"
launchctl print "gui/$(id -u)/$name" 2>&1 || true
