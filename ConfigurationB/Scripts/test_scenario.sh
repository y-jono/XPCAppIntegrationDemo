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
#   sandbox-agent      SharedService だけ App Sandbox を有効にした検証系。
#                      自分の LaunchAgent ジョブが MachServices で宣言した名前への
#                      check-in は sandbox でも許可されるため、通信は成立する
#                      （エラーが出ないことを実測で確認する）
#   sandbox-all        AppA/AppB/SharedService の3つとも App Sandbox を有効にした異常系。
#                      クライアント側の mach-lookup が sandbox に拒否され、
#                      同期呼び出しが即座に失敗する
#   quarantine-client  AppA に quarantine を付けて「配布後・未公証」のクライアント起動を
#                      再現する異常系。Gatekeeper が exec を SIGKILL し（exit 137）、
#                      出力ゼロのまま死ぬ
#   quarantine-agent   SharedService だけ quarantine を付けた検証系。launchd 経由の
#                      起動は Gatekeeper の exec 検査を受けないため通信は成立して
#                      しまう（spctl の判定は rejected のまま）
#   all                上記すべてを順に実行する（sandbox-* / quarantine-* は署名や
#                      拡張属性を差し替えるため除く）
#
# sandbox-agent / sandbox-all はビルド済み .app を Entitlements/sandboxed.entitlements で
# ad-hoc 再署名して sandbox 化し、実行後に元の entitlements へ再署名して戻す。
# Debug（ad-hoc 署名）では完全に元の状態へ戻るが、Release で実行すると署名が
# Apple Development から ad-hoc に変わったままになるため、実行後に build.sh Release で
# ビルドし直すこと。
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

# sandbox-* シナリオ用パラメータ。
# 同期 XPC 呼び出しは、launchd がサービスのポートを持ったままサービス本体が
# 応答できない状態（sandbox に阻まれた場合など）に陥ると返事を待ち続けるため、
# アプリ内タイムアウト（APPCOMM_WAIT_SECONDS）が効かないことがある。
# その場合に備えて、外側からプロセスを強制終了するウォッチドッグ秒数。
WATCHDOG_SECONDS=10
SANDBOX_ENTITLEMENTS="$ROOT/Entitlements/sandboxed.entitlements"
SERVICE_ERR_LOG="/tmp/com.example.shared.service.err.log"

# quarantine-* シナリオ用。ダウンロード配布された .app に付く検疫印を模擬する
# （フラグ 0083 = ダウンロード由来・未承認）。
QUARANTINE_VALUE="0083;00000000;reproduce;"

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

# パターンが「出ていないこと」を確認する（異常系で成功ログが無いことの検証用）。
assert_log_absent() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  [FAIL] $desc (unexpected pattern found: $pattern)"
    echo "    -- log: $file"
    fail_count=$((fail_count + 1))
  else
    echo "  [PASS] $desc"
    pass_count=$((pass_count + 1))
  fi
}

# 検出手段1: codesign で .app の App Sandbox entitlement を確認する。
# 「sandbox に阻まれているかも」と疑ったら、まず対象バイナリが本当に
# sandboxed かどうかを署名から確認するのが第一歩。
assert_sandbox_entitlement() {
  local app="$1" expected="$2" desc="$3"
  local actual
  actual="$(codesign -d --entitlements :- "$ROOT/build/$CONFIGURATION/$app.app" 2>/dev/null \
    | grep -A1 'com.apple.security.app-sandbox' | grep -oE '<(true|false)/>' | head -1)"
  if [[ "$actual" == "<$expected/>" ]]; then
    echo "  [PASS] $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] $desc (app-sandbox = ${actual:-なし}, expected <$expected/>)"
    fail_count=$((fail_count + 1))
  fi
}

# ビルド済み .app の entitlements を差し替えて ad-hoc 再署名する。
resign() {
  local app="$1" ent="$2"
  codesign --force --sign - --entitlements "$ent" "$ROOT/build/$CONFIGURATION/$app.app" 2>&1 \
    | sed 's/^/  [resign] /'
}

# SharedService の err.log は実行をまたいで追記されるため、シナリオ開始時点の
# サイズを覚えておき、今回の実行で増えた分だけを取り出す。
snapshot_err_log() { stat -f%z "$SERVICE_ERR_LOG" 2>/dev/null || echo 0; }
err_log_since() { tail -c +"$(( $1 + 1 ))" "$SERVICE_ERR_LOG" 2>/dev/null || true; }

# 検出手段3: unified log から sandbox の拒否メッセージを取り出す。
# App Sandbox が mach-lookup / mach-register を拒否すると、カーネルが
# 「Sandbox: <プロセス名>(pid) deny(1) mach-lookup <サービス名>」の形で記録する。
# アプリ側のエラー（同期 proxy error 等）には「sandbox のせい」とは書かれないため、
# この deny 行が sandbox 起因かどうかを見分ける決定的な証拠になる。
report_sandbox_denials() {
  local start="$1" out="$2"
  # sandboxd が violation レポートを書き終わるまで少し待つ。
  sleep 2
  # log はユーザーのシェル関数と衝突しうるためフルパスで呼ぶ。
  /usr/bin/log show --start "$start" --style compact \
    --predicate '(eventMessage CONTAINS "deny" OR sender == "Sandbox") AND eventMessage CONTAINS "com.example"' \
    > "$out" 2>/dev/null || true
  echo "  -- unified log の sandbox 拒否メッセージ（検出手段3: log show）:"
  if [[ -s "$out" ]] && grep -qE 'deny\(1\)' "$out"; then
    grep -E 'deny\(1\)' "$out" | sed 's/^/     /'
  else
    echo "     （拒否メッセージなし）"
  fi
}

# 検出手段4: コンテナ生成。sandboxed プロセスは初回起動時に
# ~/Library/Containers/<bundle id> が作られる。これが「実行時に本当に sandbox が
# 適用された」証拠になる（codesign は entitlement の有無しか分からない）。
container_dir_for() {
  local app="$1" bundle_id
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$ROOT/build/$CONFIGURATION/$app.app/Contents/Info.plist")"
  echo "$HOME/Library/Containers/$bundle_id"
}

# quarantine の付与・除去・確認。ダウンロード配布直後の状態を模擬/復元する。
apply_quarantine() { xattr -r -w com.apple.quarantine "$QUARANTINE_VALUE" "$ROOT/build/$CONFIGURATION/$1.app"; }
remove_quarantine() { xattr -r -d com.apple.quarantine "$ROOT/build/$CONFIGURATION/$1.app" 2>/dev/null || true; }

assert_quarantined() {
  local app="$1" desc="$2"
  if xattr -p com.apple.quarantine "$ROOT/build/$CONFIGURATION/$app.app/Contents/MacOS/$app" >/dev/null 2>&1; then
    echo "  [PASS] $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] $desc (quarantine 属性が付いていない)"
    fail_count=$((fail_count + 1))
  fi
}

# Gatekeeper の配布可否判定。未公証（ad-hoc / Apple Development）は rejected、
# Notarization 済み Developer ID 署名なら accepted になる。
assert_spctl_rejected() {
  local app="$1" desc="$2" verdict
  verdict="$(spctl --assess --type execute "$ROOT/build/$CONFIGURATION/$app.app" 2>&1 || true)"
  if echo "$verdict" | grep -q 'rejected'; then
    echo "  [PASS] $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] $desc (spctl の判定: $verdict)"
    fail_count=$((fail_count + 1))
  fi
}

# ウォッチドッグ付き実行。WATCHDOG_SECONDS 以内に終了しなければ強制終了し、
# その事実をログに残す（同期 XPC 呼び出しが返らず固まるケースの検出用）。
run_logged_watchdog() {
  local bin="$1" log="$2"
  "$bin" >"$log" 2>&1 &
  local pid=$!
  local ticks=0 limit=$(( WATCHDOG_SECONDS * 10 ))
  while kill -0 "$pid" 2>/dev/null && (( ticks < limit )); do
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    echo "[watchdog] ${WATCHDOG_SECONDS}秒以内に終了しなかったため強制終了（同期呼び出しがブロックされたまま）" >>"$log"
  fi
  wait "$pid" 2>/dev/null
  cat "$log"
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

# SharedService だけ sandbox 化する検証系。
# 実測（macOS 26 / Darwin 25）: 自分の LaunchAgent ジョブが MachServices で宣言した
# 名前への check-in は sandbox でも許可されるため、listener は正常に機能し、
# push 交換は双方向とも成立する。「Agent の sandbox 化だけでは XPC 経路は壊れない」
# ことを、実行時にコンテナが生成される（= sandbox は確かに効いている）証拠つきで確認する。
scenario_sandbox_agent() {
  echo "== シナリオ: sandbox-agent（検証系: SharedService だけ App Sandbox 有効 → 通信は成立する） =="
  local start; start="$(date '+%Y-%m-%d %H:%M:%S')"
  # 前のシナリオや手動実験の署名が残っていても成立するよう、3つとも既知の状態へ揃える。
  resign AppA "$ROOT/AppA/AppA.entitlements"
  resign AppB "$ROOT/AppB/AppB.entitlements"
  resign SharedService "$SANDBOX_ENTITLEMENTS"
  assert_sandbox_entitlement AppA false "AppA は sandboxed でない（前提の確認）"
  assert_sandbox_entitlement AppB false "AppB は sandboxed でない（前提の確認）"
  assert_sandbox_entitlement SharedService true "SharedService が sandboxed になっている（検出手段1: codesign）"
  # 実行中の旧バイナリを止め、次の接続で再署名後のバイナリを launchd に起動させる。
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true
  local container; container="$(container_dir_for SharedService)"

  local log_b="$LOG_DIR/sandbox_agent_B.log" log_a="$LOG_DIR/sandbox_agent_A.log"
  run_pair "$APP_B" "$log_b" "$APP_A" "$log_a" "$STAGGER_NORMAL_SECONDS"

  assert_log "$log_a" 'push 受信 from=AppB' "AppA が AppB からの push を受信（sandbox 化しても成立）"
  assert_log "$log_b" 'push 受信 from=AppA' "AppB が AppA からの push を受信（sandbox 化しても成立）"
  # コンテナディレクトリは containermanagerd に保護されており消せないため、
  # 「存在する = sandboxed として起動したことがある」ことの確認に留める。
  if [[ -d "$container" ]]; then
    echo "  [PASS] コンテナが存在する = 実行時に sandbox が適用された（検出手段4: $container）"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] コンテナが生成されていない（sandbox が実行時に適用されなかった可能性）"
    fail_count=$((fail_count + 1))
  fi

  report_sandbox_denials "$start" "$LOG_DIR/sandbox_agent_denials.log"
  assert_log_absent "$LOG_DIR/sandbox_agent_denials.log" 'deny\(1\) mach-' "mach 系の deny は記録されない（自ジョブの MachServices check-in は許可される）"

  echo "  -> SharedService を元の entitlements に戻します"
  resign SharedService "$ROOT/SharedService/SharedService.entitlements"
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true
}

# 3つとも sandbox 化する異常系。
# 実測: クライアント側の mach-lookup が sandbox に拒否され、接続は即座に invalidation、
# 同期呼び出しはすべて「同期 proxy error: Couldn't communicate with a helper application.」
# になる。launchd に要求が届かないため SharedService は起動すらしない。
# sandboxd が「Sandbox: AppA(pid) deny(1) mach-lookup com.example.shared.service」を
# unified log（com.apple.sandbox.reporting:violation）に記録する。
scenario_sandbox_all() {
  echo "== シナリオ: sandbox-all（異常系: AppA/AppB/SharedService すべて App Sandbox 有効） =="
  local start; start="$(date '+%Y-%m-%d %H:%M:%S')"
  local err_off; err_off="$(snapshot_err_log)"
  local app
  for app in AppA AppB SharedService; do
    resign "$app" "$SANDBOX_ENTITLEMENTS"
  done
  for app in AppA AppB SharedService; do
    assert_sandbox_entitlement "$app" true "$app が sandboxed になっている（検出手段1: codesign）"
  done
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true

  local log_a="$LOG_DIR/sandbox_all_A.log"
  run_logged_watchdog "$APP_A" "$log_a"

  assert_log_absent "$log_a" 'push 受信' "push 交換が成立しない"
  assert_log "$log_a" '同期 proxy error' "lookup 拒否により同期呼び出しがエラーになる（検出手段2: アプリのログ）"
  assert_log "$log_a" 'invalidation' "接続が即座に invalidation される"
  local err_new; err_new="$(err_log_since "$err_off")"
  if [[ -z "$err_new" ]]; then
    echo "  [PASS] SharedService は起動すらしない（launchd に lookup 要求が届かないため）"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] SharedService 側にログが出ている（lookup が届いてしまっている）:"
    echo "$err_new" | sed 's/^/     /'
    fail_count=$((fail_count + 1))
  fi

  report_sandbox_denials "$start" "$LOG_DIR/sandbox_all_denials.log"
  assert_log "$LOG_DIR/sandbox_all_denials.log" 'deny.*mach-lookup|mach-lookup.*deny' "unified log にクライアントの mach-lookup 拒否が記録される（検出手段3: log show）"

  echo "  -> 3つの .app を元の entitlements に戻します"
  resign AppA "$ROOT/AppA/AppA.entitlements"
  resign AppB "$ROOT/AppB/AppB.entitlements"
  resign SharedService "$ROOT/SharedService/SharedService.entitlements"
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true
}

# AppA に quarantine を付け、「ダウンロード配布した未公証アプリをユーザーが起動した」
# 状態を再現する異常系。
# 実測（macOS 26）: シェル / Finder からの起動は Gatekeeper が exec 時点で SIGKILL
# する（exit 137）。プロセスは 1 行もログを出せないまま死ぬため、アプリ側のログ
# だけを見ていると「何も起きていない」ように見えるのが特徴。
# Notarization 済みなら同じ操作で起動できる（spctl も accepted になる）。
scenario_quarantine_client() {
  echo "== シナリオ: quarantine-client（異常系: 配布後・未公証のクライアントを起動） =="
  echo "  （注意: 実行中に『開発元を確認できないため開けません』のダイアログが出ることがあります）"
  apply_quarantine AppA
  assert_quarantined AppA "AppA に quarantine が付いている（配布直後の状態）"
  assert_spctl_rejected AppA "spctl の配布可否判定が rejected（未公証のため）"

  local log_a="$LOG_DIR/quarantine_client_A.log" exit_code
  "$APP_A" >"$log_a" 2>&1
  exit_code=$?
  if (( exit_code == 137 )); then
    echo "  [PASS] Gatekeeper により exec 時点で SIGKILL される（exit 137）"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] SIGKILL されなかった（exit=$exit_code）"
    fail_count=$((fail_count + 1))
  fi
  if [[ ! -s "$log_a" ]]; then
    echo "  [PASS] 1 行もログを出せないまま死ぬ（出力が空）"
    pass_count=$((pass_count + 1))
  else
    echo "  [FAIL] 出力がある（SIGKILL 前に実行されている）:"
    sed 's/^/     /' "$log_a"
    fail_count=$((fail_count + 1))
  fi

  echo "  -> AppA の quarantine を解除します"
  remove_quarantine AppA
}

# SharedService だけに quarantine を付けた検証系。
# 実測（macOS 26）: launchd（LaunchAgent）経由の起動は Gatekeeper の exec 検査を
# 受けないため、quarantine 付き・未公証でも SharedService は起動し、通信は成立して
# しまう。「クライアントは Gatekeeper に殺されるのに、サービスは動く」という
# ちぐはぐな状態が起き得ることを示す。配布可否（spctl）は rejected のまま。
scenario_quarantine_agent() {
  echo "== シナリオ: quarantine-agent（検証系: SharedService だけ quarantine 付き → launchd 経由では起動できてしまう） =="
  apply_quarantine SharedService
  assert_quarantined SharedService "SharedService に quarantine が付いている（配布直後の状態）"
  assert_spctl_rejected SharedService "spctl の配布可否判定が rejected（未公証のため）"
  # 実行中の旧プロセスを止め、次の接続で quarantine 付きバイナリを launchd に起動させる。
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true

  local log_b="$LOG_DIR/quarantine_agent_B.log" log_a="$LOG_DIR/quarantine_agent_A.log"
  run_pair "$APP_B" "$log_b" "$APP_A" "$log_a" "$STAGGER_NORMAL_SECONDS"

  assert_log "$log_a" 'push 受信 from=AppB' "AppA が push を受信（launchd 経由は Gatekeeper 検査を受けない）"
  assert_log "$log_b" 'push 受信 from=AppA' "AppB が push を受信（launchd 経由は Gatekeeper 検査を受けない）"

  echo "  -> SharedService の quarantine を解除します"
  remove_quarantine SharedService
  "$ROOT/Scripts/cleanup_processes.sh" >/dev/null 2>&1 || true
}

run_scenario() {
  case "$1" in
    normal) scenario_normal ;;
    reverse-order) scenario_reverse_order ;;
    simultaneous) scenario_simultaneous ;;
    peer-absent) scenario_peer_absent ;;
    no-shared-service) scenario_no_shared_service ;;
    sandbox-agent) scenario_sandbox_agent ;;
    sandbox-all) scenario_sandbox_all ;;
    quarantine-client) scenario_quarantine_client ;;
    quarantine-agent) scenario_quarantine_agent ;;
    *)
      echo "unknown scenario: $1" >&2
      echo "usage: $0 <Configuration> <normal|reverse-order|simultaneous|peer-absent|no-shared-service|sandbox-agent|sandbox-all|quarantine-client|quarantine-agent|all>" >&2
      echo "  (省略時 Configuration=Debug, scenario=normal)" >&2
      echo "  (all は sandbox-* / quarantine-* を含まない。署名や拡張属性を差し替えるため個別に実行する)" >&2
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
