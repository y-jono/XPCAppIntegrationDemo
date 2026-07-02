# XPC 切り分け手順

Debug では成功し Release では失敗する原因を、順番に確認していくためのコマンド集です。

用語が分からない場合は先に [PRIMER.md](PRIMER.md) を読んでください。全体の概要は [README.md](README.md) にあります。

## 確認する順番

上から順に見ていくのが効率的です。このプロジェクトのアプリはコード側で接続を拒否しないため、原因は多くの場合 1〜3（登録・パス・登録場所）にあります。

1. Mach サービスが launchd に登録されているか
2. LaunchAgent が正しいビルドの `.app` を指しているか（最頻出）
3. 正しい bootstrap domain（登録場所）を見ているか
4. Bundle ID が意図どおりか
5. Hardened Runtime / entitlements の差
6. quarantine / App Translocation でパスがずれていないか
7. 同期呼び出しのエラーと push の到達をログで確認する
8. App Sandbox が Mach サービスの照会を拒否していないか

> このプロジェクトは Apple Developer Program メンバーシップが期限切れの前提です。そのため Developer ID Application 証明書と Notarization（公証）は扱いません。Release は Apple Development 署名 + Team ID `EXAMPLE123` + Hardened Runtime で再現します。

## 1. Mach サービスの登録

Mach サービス名は launchd に登録されて初めて、他プロセスから見つけられます（lookup できます）。未登録なら通信は始まりません。

```sh
launchctl print "gui/$(id -u)/com.example.shared.service"
launchctl print "gui/$(id -u)" | grep -A5 -E 'com\.example\.shared'
```

登録されていないときの出力例:

```sh
launchctl print "gui/$(id -u)/com.example.shared.service"
# Could not find service "com.example.shared.service" in domain for uid ...
```

判定: `Could not find service` が出たら未登録です。この状態では SharedService への接続は成立しません。`ConfigurationB/Scripts/install_launchagents.sh Debug` を実行して登録し直してください。

## 2. LaunchAgent が指すパス

Release 失敗で最初に疑う項目です。理由は、Release をビルドしても plist が古い Debug の `.app`（`build/Debug/.../Contents/MacOS/<exec>`）を指したままだと、launchd が Debug を起動してしまうからです。

```sh
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist"
ls -l /path/to/SharedService.app/Contents/MacOS/SharedService
plutil -extract CFBundlePackageType raw /path/to/SharedService.app/Contents/Info.plist
codesign -dv --verbose=4 /path/to/SharedService.app 2>&1
codesign -dv --verbose=4 /path/to/SharedService.app/Contents/MacOS/SharedService 2>&1
```

判定: `ProgramArguments` が `build/Debug/...` を指していたら、Release を検証しているつもりでも実際は Debug が動いています。

修正:

```sh
ConfigurationB/Scripts/build.sh Release
ConfigurationB/Scripts/install_launchagents.sh Release
launchctl kickstart -k "gui/$(id -u)/com.example.shared.service"
```

## 3. bootstrap domain（登録場所）

同じサービス名でも、登録される場所（domain）が違えば別物として扱われます。`system`、`user/<uid>`、`gui/<uid>` は別の domain です。GUI アプリの LaunchAgent は通常 `gui/<uid>` に登録します。

```sh
id -u
launchctl print "gui/$(id -u)/com.example.shared.service"
launchctl print "user/$(id -u)/com.example.shared.service" 2>&1 || true
sudo launchctl print "system/com.example.shared.service" 2>&1 || true
```

判定: `gui/<uid>` にだけ存在するなら、同じログインセッションの中から確認してください。`sudo` や別ユーザーから探すと、別の domain を見ているため見つかりません。

## 4. Bundle ID の確認

Debug は `com.example.shared.service.Debug`、Release は `com.example.shared.service` のように Bundle ID が変わります（`.Debug` の有無）。意図どおりの差になっているかを確認します。

```sh
codesign -dv --verbose=4 ConfigurationB/build/Debug/SharedService.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -dv --verbose=4 ConfigurationB/build/Release/SharedService.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -d --entitlements :- ConfigurationB/build/Debug/SharedService.app 2>/dev/null
codesign -d --entitlements :- ConfigurationB/build/Release/SharedService.app 2>/dev/null
```

判定: `Identifier` と `TeamIdentifier` が期待どおりで、Debug と Release の差が意図したものになっているかを確認します。

## 5. Hardened Runtime / entitlements

Release だけ Hardened Runtime（追加のセキュリティ制限）が有効です。entitlements（アプリに許可された特権の一覧）の差を確認します。

```sh
codesign -dv --verbose=4 /path/to/Release/SharedService.app 2>&1 | egrep 'Runtime|flags|TeamIdentifier'
codesign -d --entitlements :- /path/to/Release/SharedService.app 2>/dev/null
codesign -d --entitlements :- /path/to/Debug/SharedService.app 2>/dev/null
```

判定: `get-task-allow`（デバッガ接続の許可。Debug のみ）や Library Validation（署名元が異なるライブラリの読み込み禁止）などの差が、通信相手の起動や周辺処理に影響していないか確認します。ただし Mach サービスの lookup 自体は entitlement ではなく launchd への登録が前提です。Hardened Runtime が XPC 通信そのものを止めるわけではありません。

## 6. quarantine / App Translocation

quarantine（ダウンロード由来のファイルに付く印）が残った `.app` を、Downloads などから移動せずに起動すると、macOS が実行ファイルを `/private/var/folders/.../AppTranslocation/...` という読み取り専用の一時パスにコピーして動かすことがあります（App Translocation）。LaunchAgent は固定パスを前提にしているため、パスがずれると起動対象を見失います。

```sh
xattr -lr /path/to/App.app | grep -i quarantine || true
xattr -d com.apple.quarantine /path/to/App.app 2>/dev/null || true
spctl --assess --type execute --verbose=4 /path/to/App.app
codesign --verify --deep --strict --verbose=4 /path/to/App.app
pgrep -fl 'AppA|AppB|SharedService'
ps -axo pid,comm,args | grep -E 'AppA|AppB|SharedService|AppTranslocation'
log stream --style compact --predicate 'eventMessage CONTAINS "AppTranslocation" OR eventMessage CONTAINS "quarantine"'
```

判定: quarantine が付いている、または実行パスが `/private/var/folders/.../AppTranslocation/...` になっているなら、`.app` を `/Applications` などの正式な場所へ移動し、quarantine を外してから LaunchAgent を登録し直してください。

## 7. 同期呼び出しのエラーと push の到達

`register` / `send` は同期呼び出し（返事が来るまで待つ呼び出し）なので、エラーをログに出していないと失敗理由を確認できません。本プロジェクトは `同期 proxy error:` を stderr に出します。

push はメッセージをためる仕組み（mailbox）を持たないため、宛先が接続中でないと `send` は成功したまま `delivered=false` になり、メッセージはそのまま失われます（エラーにはなりません）。

```sh
ConfigurationB/Scripts/test_scenario.sh Debug normal 2>&1 | tee /tmp/xpc-b-test.log
grep -E '同期 proxy error|interruption|invalidation|register結果|送信結果|push 受信' /tmp/xpc-b-test.log
tail -f /tmp/com.example.shared.service.err.log
```

判定: `送信結果 ... delivered=false` が出ていれば、push を送った時点で相手が SharedService に接続していなかったことが確定します。`register結果 ok=false` になる場合や、エラーが出ないまま止まる場合は、相手プロセスの stderr、LaunchAgent の `StandardErrorPath`、`log stream` を同時に確認します。

`test_scenario.sh` には `peer-absent`（相手アプリが不在）、`no-shared-service`（SharedService が未登録）などの異常系シナリオもあります。`ConfigurationB/Scripts/test_scenario.sh Debug all` で正常系・代替形・異常系をまとめて再現し、ログの `grep` で自動的に PASS / FAIL を判定できます。

## 8. App Sandbox による拒否

Notarization を見据えて App Sandbox（`com.apple.security.app-sandbox`）を有効にすると、XPC の Mach サービス通信に影響が出ることがあります。専用のシナリオで再現できます（署名を一時的に差し替え、終了後に元へ戻します）。

```sh
ConfigurationB/Scripts/test_scenario.sh Debug sandbox-agent   # SharedService だけ sandbox 化
ConfigurationB/Scripts/test_scenario.sh Debug sandbox-all     # 3 つとも sandbox 化
```

実測（macOS 26）での挙動:

| 構成 | 結果 |
|---|---|
| SharedService（listener）だけ sandbox 化 | **通信は成立する**。自分の LaunchAgent ジョブが `MachServices` で宣言した名前への check-in は sandbox でも許可される。エラーは出ない |
| クライアント（AppA / AppB）も sandbox 化 | クライアントの mach-lookup が拒否される。接続は即座に `invalidation`、同期呼び出しはすべて `同期 proxy error: Couldn't communicate with a helper application.`。SharedService は起動すらしない |

### sandbox に阻まれたことの検出方法

アプリ側のエラー（`同期 proxy error` など）には「sandbox のせい」とは書かれず、LaunchAgent 未登録（原因 #1）と同じ見た目になります。次の 4 つで見分けます。

**手段 1: 署名の entitlements を確認する（sandboxed かどうか）**

```sh
codesign -d --entitlements :- /path/to/AppA.app 2>/dev/null | grep -A1 app-sandbox
```

`<true/>` なら sandboxed です。まず関係者全員（クライアントと listener）の署名を確認します。

**手段 2: アプリ自身のログを見る（症状の把握）**

`同期 proxy error` + 即時の `invalidation` は「照会が失敗した」ことしか示しません。原因 #1（未登録）との違いは手段 3 で確定させます。

**手段 3: unified log の deny メッセージを見る（決定的な証拠）**

sandbox が拒否すると、`sandboxd` が `com.apple.sandbox.reporting:violation` に記録します。

```sh
/usr/bin/log show --last 5m --style compact \
  --predicate '(eventMessage CONTAINS "deny" OR sender == "Sandbox") AND eventMessage CONTAINS "com.example"'
# 出力例:
# sandboxd[...] Sandbox: AppA(79400) deny(1) mach-lookup com.example.shared.service
```

`deny(1) mach-lookup <サービス名>` が出ていれば、sandbox が照会を拒否したことが確定します。`launchctl print` で未登録なら原因 #1、登録済みなのに deny が出るなら sandbox が原因です。

**手段 4: コンテナ生成を確認する（実行時に sandbox が効いたか）**

sandboxed プロセスは初回起動時に `~/Library/Containers/<Bundle ID>` が作られます。手段 1 は「entitlement が付いているか」しか分からないのに対し、こちらは「実際に sandbox 下で動いたか」の証拠になります。

```sh
ls -d ~/Library/Containers/com.example.shared.service.Debug
```

### sandboxed クライアントから接続したい場合の対処

- **App Group を使う**: Mach サービス名を App Group ID で始まる名前（例 `<TeamID>.com.example.shared.service`）にし、クライアントに `com.apple.security.application-groups` を付けると、sandboxed アプリでも照会が許可されます。
- **一時例外 entitlement**: `com.apple.security.temporary-exception.mach-lookup.global-name` にサービス名を列挙すると照会できます。ただし Mac App Store の審査では原則通らないため、Developer ID 配布向けの手段です。

## Release 失敗の切り分け手順

1. `ConfigurationB/Scripts/build.sh Release` を実行する。
2. `install_launchagents.sh Release` で plist を Release の `.app` の絶対パスに登録し直す。
3. `launchctl print "gui/$(id -u)/..."` で `program` と `MachServices` を確認する。
4. `codesign -dv --verbose=4` と `codesign -d --entitlements :-` で Debug/Release の差を確認する。
5. `log stream` と `/tmp/com.example.shared.service.err.log` を見ながらテストスクリプトを実行する。

## LaunchAgent が Debug を指したままになる問題の再現

「2. LaunchAgent が指すパス」で説明した問題は、次の手順で再現できます。

```sh
ConfigurationB/Scripts/build.sh Debug
ConfigurationB/Scripts/install_launchagents.sh Debug
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist" | grep ProgramArguments -A4

ConfigurationB/Scripts/build.sh Release
ConfigurationB/Scripts/test_scenario.sh Release
```

この時点で plist が `build/Debug/SharedService.app/Contents/MacOS/SharedService` を指していれば、Release を検証しているつもりでも launchd は Debug を起動しています。Release の LaunchAgent を登録し直せば解消します。

```sh
ConfigurationB/Scripts/install_launchagents.sh Release
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist" | grep ProgramArguments -A4
```
