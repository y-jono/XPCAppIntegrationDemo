#!/bin/zsh
set -uo pipefail
# このリポジトリの実験一式（ビルド → LaunchAgent 登録 → 基本シナリオ →
# App Sandbox 検証）を、クローン直後の状態から一発で再現するスクリプト。
#
# 使い方:
#   ConfigurationB/Scripts/reproduce.sh [Configuration]
#
# Configuration 省略時は Debug。Debug は ad-hoc 署名なので
# Apple Developer アカウントなしで最後まで実行できる。
# Release を指定する場合は README の「セットアップ」にある Team ID の
# 置き換えが先に必要。
#
# 実行後の後片付け（LaunchAgent の登録解除）:
#   ConfigurationB/Scripts/uninstall_launchagents.sh

CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 前提条件の確認。xcodebuild が無ければ何もできないので先に案内する。
if ! xcode-select -p >/dev/null 2>&1; then
  echo "エラー: Xcode（Command Line Tools ではなく本体）が必要です。" >&2
  echo "App Store から Xcode をインストールし、次を実行してください:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

typeset -a step_names step_results

run_step() {
  local name="$1"; shift
  echo
  echo "##########################################################"
  echo "## $name"
  echo "##########################################################"
  if "$@"; then
    step_names+=("$name"); step_results+=("OK")
  else
    step_names+=("$name"); step_results+=("NG")
  fi
}

run_step "1/5 ビルド ($CONFIGURATION)"            "$ROOT/Scripts/build.sh" "$CONFIGURATION"
run_step "2/5 LaunchAgent 登録"                    "$ROOT/Scripts/install_launchagents.sh" "$CONFIGURATION"
run_step "3/5 基本シナリオ一式 (all)"              "$ROOT/Scripts/test_scenario.sh" "$CONFIGURATION" all
run_step "4/5 App Sandbox 検証 (sandbox-agent)"    "$ROOT/Scripts/test_scenario.sh" "$CONFIGURATION" sandbox-agent
run_step "5/5 App Sandbox 検証 (sandbox-all)"      "$ROOT/Scripts/test_scenario.sh" "$CONFIGURATION" sandbox-all

# sandbox-* シナリオは .app を ad-hoc で再署名する。Debug は元々 ad-hoc なので
# 元通りだが、Release は署名が変わったままになるため、ビルドし直して復元する。
if [[ "$CONFIGURATION" != "Debug" ]]; then
  run_step "後処理: 再ビルドで署名を復元 ($CONFIGURATION)" "$ROOT/Scripts/build.sh" "$CONFIGURATION"
fi

echo
echo "==========================================================="
echo "==== 再現結果まとめ"
echo "==========================================================="
failed=0
for i in {1..${#step_names[@]}}; do
  echo "  [${step_results[$i]}] ${step_names[$i]}"
  [[ "${step_results[$i]}" == "NG" ]] && failed=1
done
echo
if (( failed )); then
  echo "NG のステップがあります。各ステップの [FAIL] 行と DIAGNOSIS.md を確認してください。"
else
  echo "すべて成功しました。個別に試すには test_scenario.sh を直接実行してください。"
fi
echo "後片付け（LaunchAgent 登録解除）: $ROOT/Scripts/uninstall_launchagents.sh"
exit $failed
