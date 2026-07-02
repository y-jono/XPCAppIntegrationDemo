#!/bin/zsh
set -uo pipefail
# SharedService/AppA/AppB の疎通確認・制御シーケンステストを行う唯一のスクリプト。
# 起動順序・SharedService 未起動・push 未到達までパラメタライズドにテストする。
# 個々のテストパラメータは直値にせず、ここでのみ定義する。
#
# 使い方:
#   test_scenario.sh <Configuration> <scenario>
#
# scenario（省略時 normal）:
#   normal             AppB→AppA の順で起動する基本の正常系
#   reverse-order      AppA→AppB の順で起動する代替形（起動順序が入れ替わっても成立する）
#   simultaneous       AppA/AppB をほぼ同時に起動する代替形
#   peer-absent        相手アプリを起動しない異常系（push 未到達 = delivered=false）
#   no-shared-service  SharedService が launchd に未登録の異常系
#   all                上記すべてを順に実行する
#
# 各プロセスの生ログはそのまま stdout にも流れるので、DIAGNOSIS.md の grep ベースの
# 切り分け手順にも使える（例: test_scenario.sh Debug normal 2>&1 | tee /tmp/xpc-b-test.log）。
#
# 前提: SharedService の LaunchAgent は install_launchagents.sh で事前に登録済みであること。
# ただし no-shared-service シナリオは自分で一時的に登録解除し、実行後に再登録して元に戻す。

CONFIGURATION="${1:-Debug}"
SCENARIO="${2:-normal}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 送受信のタイミングを決めるテストパラメータ。AppA/AppB 側には直値を持たせず、ここから
# 環境変数として渡す。
APPCOMM_WAIT_SECONDS=2.0        # push を受け取れる猶予時間（タイムアウト）
APPCOMM_SEND_DELAY_SECONDS=0.5  # register 直後、相手の register 完了を待つための送信遅延
export APPCOMM_WAIT_SECONDS APPCOMM_SEND_DELAY_SECONDS

# 起動順序のバリエーションを決めるテストパラメータ（スタガー = 先発と後発の起動間隔）。
STAGGER_NORMAL_SECONDS=0.3
STAGGER_SIMULTANEOUS_SECONDS=0

APP_A="$ROOT/build/$CONFIGURATION/AppA.app/Contents/MacOS/AppA"
APP_B="$ROOT/build/$CONFIGURATION/AppB.app/Contents/MacOS/AppB"
LOG_DIR="$(mktemp -d)"

pass_count=0
fail_count=0

cleanup() { rm -rf "$LOG_DIR"; }
trap cleanup EXIT

assert_log() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  [PASS] $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] $desc (pattern not found: $pattern)"
    echo "    -- log: $file"
    fail_count=$((fail_count + 1))
  fi
}

# 生ログを stdout にも流しつつ、判定用にファイルへも残す。
run_logged() {
  local bin="$1" log="$2"
  "$bin" 2>&1 | tee "$log"
}

# 2プロセスを stagger 秒差で起動し、両方の終了を待つ。
run_pair() {
  local first_bin="$1" first_log="$2" second_bin="$3" second_log="$4" stagger="$5"
  run_logged "$first_bin" "$first_log" &
  local first_pid=$!
  sleep "$stagger"
  run_logged "$second_bin" "$second_log"
  wait "$first_pid"
}

scenario_normal() {
  echo "== シナリオ: normal（正常系: AppB→AppA の順で起動） =="
  local log_b="$LOG_DIR/normal_B.log" log_a="$LOG_DIR/normal_A.log"
  run_pair "$APP_B" "$log_b" "$APP_A" "$log_a" "$STAGGER_NORMAL_SECONDS"
  assert_log "$log_a" 'push 受信 from=AppB' "AppA が AppB からの push を受信"
  assert_log "$log_b" 'push 受信 from=AppA' "AppB が AppA からの push を受信"
  assert_log "$log_a" '送信結果 to=AppB delivered=true' "AppA→AppB delivered=true"
  assert_log "$log_b" '送信結果 to=AppA delivered=true' "AppB→AppA delivered=true"
}

scenario_reverse_order() {
  echo "== シナリオ: reverse-order（代替形: AppA→AppB の順で起動） =="
  local log_a="$LOG_DIR/reverse_A.log" log_b="$LOG_DIR/reverse_B.log"
  run_pair "$APP_A" "$log_a" "$APP_B" "$log_b" "$STAGGER_NORMAL_SECONDS"
  assert_log "$log_a" 'push 受信 from=AppB' "AppA が AppB からの push を受信"
  assert_log "$log_b" 'push 受信 from=AppA' "AppB が AppA からの push を受信"
}

scenario_simultaneous() {
  echo "== シナリオ: simultaneous（代替形: AppA/AppB をほぼ同時に起動） =="
  local log_a="$LOG_DIR/sim_A.log" log_b="$LOG_DIR/sim_B.log"
  run_pair "$APP_A" "$log_a" "$APP_B" "$log_b" "$STAGGER_SIMULTANEOUS_SECONDS"
  assert_log "$log_a" 'push 受信 from=AppB' "AppA が AppB からの push を受信"
  assert_log "$log_b" 'push 受信 from=AppA' "AppB が AppA からの push を受信"
}

scenario_peer_absent() {
  echo "== シナリオ: peer-absent（異常系: 相手アプリ不在で push 未到達） =="
  local log_a="$LOG_DIR/absent_A.log"
  run_logged "$APP_A" "$log_a"
  assert_log "$log_a" '送信結果 to=AppB delivered=false' "相手不在のため delivered=false になる"
  assert_log "$log_a" '待機タイムアウト' "push を受信できないままタイムアウトで終了する"
}

scenario_no_shared_service() {
  echo "== シナリオ: no-shared-service（異常系: SharedService が launchd 未登録） =="
  "$ROOT/Scripts/uninstall_launchagents.sh" >/dev/null 2>&1 || true
  local log_a="$LOG_DIR/noservice_A.log"
  run_logged "$APP_A" "$log_a"
  assert_log "$log_a" '同期 proxy error' "SharedService 未登録により同期呼び出しがエラーになる"
  assert_log "$log_a" '待機タイムアウト' "接続できないままタイムアウトで終了する"
  echo "  -> SharedService の LaunchAgent を再登録します"
  "$ROOT/Scripts/install_launchagents.sh" "$CONFIGURATION" >/dev/null 2>&1
}

run_scenario() {
  case "$1" in
    normal) scenario_normal ;;
    reverse-order) scenario_reverse_order ;;
    simultaneous) scenario_simultaneous ;;
    peer-absent) scenario_peer_absent ;;
    no-shared-service) scenario_no_shared_service ;;
    *)
      echo "unknown scenario: $1" >&2
      echo "usage: $0 <Configuration> <normal|reverse-order|simultaneous|peer-absent|no-shared-service|all>" >&2
      echo "  (省略時 Configuration=Debug, scenario=normal)" >&2
      exit 1
      ;;
  esac
}

if [[ "$SCENARIO" == "all" ]]; then
  # no-shared-service は SharedService を一時的に止めるため最後に実行する。
  for s in normal reverse-order simultaneous peer-absent no-shared-service; do
    run_scenario "$s"
  done
else
  run_scenario "$SCENARIO"
fi

"$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true

echo
echo "==== 結果: PASS=$pass_count FAIL=$fail_count ===="
[[ "$fail_count" -eq 0 ]]
