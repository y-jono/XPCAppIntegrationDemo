#!/bin/zsh
set -euo pipefail

# テスト実行後に残った AppA/AppB/SharedService のプロセスを、Configuration や起動時の
# パス指定（絶対/相対）を問わず終了する。タイムアウトの取りこぼしや異常終了で残存した
# 場合の後片付け用。LaunchAgent 自体の登録解除は uninstall_launchagents.sh を使う。
for app in AppA AppB SharedService; do
  pkill -f "${app}\.app/Contents/MacOS/${app}$" 2>/dev/null || true
done

pgrep -fl '(AppA|AppB|SharedService)\.app/Contents/MacOS/' || echo "残存プロセスなし"
