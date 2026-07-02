# XPC 切り分け手順

この文書は Debug 成功 / Release 失敗を、コード、launchd、署名、Hardened Runtime、quarantine / App Translocation に分けて確認するためのコマンド集です。Apple Developer Program メンバーシップ期限切れのため Developer ID Application 証明書と Notarization は対象外です。Release は Apple Development / Team ID `EXAMPLE123` + Hardened Runtime で再現します。

## 1. Mach service 登録

named Mach service は launchd の `MachServices` に登録されている必要があります。未登録なら peer から lookup できません。

```sh
launchctl print "gui/$(id -u)/com.example.shared.service"
launchctl print "gui/$(id -u)" | grep -A5 -E 'com\.example\.shared'
```

失敗例:

```sh
launchctl print "gui/$(id -u)/com.example.shared.service"
# Could not find service "com.example.shared.service" in domain for uid ...
```

採否: これが失敗する場合、`SharedService` への接続は本質的に失敗します。`ConfigurationB/Scripts/install_launchagents.sh Debug` を実行して再登録します。

## 2. LaunchAgent の ProgramArguments パス

Release 失敗で最優先に見る項目です。plist が Debug の `.app/Contents/MacOS/<exec>` や古い DerivedData を指していないか確認します。

```sh
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist"
ls -l /path/to/SharedService.app/Contents/MacOS/SharedService
plutil -extract CFBundlePackageType raw /path/to/SharedService.app/Contents/Info.plist
codesign -dv --verbose=4 /path/to/SharedService.app 2>&1
codesign -dv --verbose=4 /path/to/SharedService.app/Contents/MacOS/SharedService 2>&1
```

修正:

```sh
ConfigurationB/Scripts/build.sh Release
ConfigurationB/Scripts/install_launchagents.sh Release
launchctl kickstart -k "gui/$(id -u)/com.example.shared.service"
```

## 3. bootstrap domain

同じ service 名でも `system`、`user/<uid>`、`gui/<uid>` は別 domain です。GUI アプリの LaunchAgent は通常 `gui/<uid>` へ登録します。

```sh
id -u
launchctl print "gui/$(id -u)/com.example.shared.service"
launchctl print "user/$(id -u)/com.example.shared.service" 2>&1 || true
sudo launchctl print "system/com.example.shared.service" 2>&1 || true
```

採否: `gui/<uid>` にだけ存在するなら、同じ login session の GUI/CLI から検証します。sudo や別ユーザーからの lookup は別問題です。

## 4. Bundle ID suffix の確認

Debug は `com.example.shared.service.Debug`、Release は `com.example.shared.service` のように bundle id が変わります。本プロジェクトの pbxproj も差を明示しています。

```sh
codesign -dv --verbose=4 ConfigurationB/build/Debug/SharedService.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -dv --verbose=4 ConfigurationB/build/Release/SharedService.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -d --entitlements :- ConfigurationB/build/Debug/SharedService.app 2>/dev/null
codesign -d --entitlements :- ConfigurationB/build/Release/SharedService.app 2>/dev/null
```

採否: Identifier や TeamIdentifier が期待通りか、Debug/Release で意図した差になっているかを確認します。

## 5. Hardened Runtime / entitlements

Release だけ `ENABLE_HARDENED_RUNTIME=YES` です。entitlements の差を確認します。

```sh
codesign -dv --verbose=4 /path/to/Release/SharedService.app 2>&1 | egrep 'Runtime|flags|TeamIdentifier'
codesign -d --entitlements :- /path/to/Release/SharedService.app 2>/dev/null
codesign -d --entitlements :- /path/to/Debug/SharedService.app 2>/dev/null
```

採否: `get-task-allow` の有無、Library Validation、JIT、Apple Events などが通信相手のロードや補助処理に影響していないかを確認します。XPC lookup そのものは entitlement ではなく launchd 登録が前提です。

## 6. Quarantine / App Translocation

Notarization はメンバーシップ無効のため対象外です。quarantine が残った `.app` を Downloads 等から起動すると translocation により `/private/var/folders/.../AppTranslocation/...` 配下へ実行パスが変わる場合があります。LaunchAgent が固定パスを指す設計では致命的です。

```sh
xattr -lr /path/to/App.app | grep -i quarantine || true
xattr -d com.apple.quarantine /path/to/App.app 2>/dev/null || true
spctl --assess --type execute --verbose=4 /path/to/App.app
codesign --verify --deep --strict --verbose=4 /path/to/App.app
pgrep -fl 'AppA|AppB|SharedService'
ps -axo pid,comm,args | grep -E 'AppA|AppB|SharedService|AppTranslocation'
log stream --style compact --predicate 'eventMessage CONTAINS "AppTranslocation" OR eventMessage CONTAINS "quarantine"'
```

採否: quarantine がある、または実行パスが `/private/var/folders/.../AppTranslocation/...` なら、正式なインストール先へ移動し、quarantine を解除または notarization 済み配布にしてから LaunchAgent を再生成します。

## 7. 同期 XPC 呼び出しの errorHandler と push の到達確認

`register`/`send` は同期呼び出しなので失敗点を見失いやすく、必ず handler をログ化します。本プロジェクトでは `同期 proxy error:` を stderr に出します。push は mailbox を持たないため、相手が未接続なら `send` は成功したまま `delivered=false` になり、メッセージはそのまま失われます（エラーにはなりません）。

```sh
ConfigurationB/Scripts/test_scenario.sh Debug normal 2>&1 | tee /tmp/xpc-b-test.log
grep -E '同期 proxy error|interruption|invalidation|register結果|送信結果|push 受信' /tmp/xpc-b-test.log
tail -f /tmp/com.example.shared.service.err.log
```

採否: `送信結果 ... delivered=false` が出ていれば、push 送信時点で相手が SharedService に接続していなかったことが確定します。`register結果 ok=false` や error handler が出ずに停止する場合は、相手 process の stderr、LaunchAgent の `StandardErrorPath`、`log stream` を同時に見ます。

`test_scenario.sh` には `peer-absent`（相手アプリ不在）、`no-shared-service`（SharedService 未登録）など異常系シナリオも用意されています。`ConfigurationB/Scripts/test_scenario.sh Debug all` で正常系・代替形・異常系をまとめて再現し、ログを `grep` して自動で PASS/FAIL 判定できます。

## Release 失敗の切り分け手順

1. `ConfigurationB/Scripts/build.sh Release` を実行する。
2. `install_launchagents.sh Release` で plist を Release の `.app/Contents/MacOS/<exec>` 絶対パスへ再生成する。
3. `launchctl print gui/$(id -u)/...` で `program` と `MachServices` を確認する。
4. `codesign -dv --verbose=4` と `codesign -d --entitlements :-` で Debug/Release 差を確認する。
5. `log stream` と `/tmp/com.example.*.err.log` を見ながら test script を実行する。

## Debug パス事故の再現

原因 #2 は LaunchAgent が Debug の `.app` を指したままになる事故です。

```sh
ConfigurationB/Scripts/build.sh Debug
ConfigurationB/Scripts/install_launchagents.sh Debug
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist" | grep ProgramArguments -A4

ConfigurationB/Scripts/build.sh Release
ConfigurationB/Scripts/test_scenario.sh Release
```

この時点で plist が `build/Debug/SharedService.app/Contents/MacOS/SharedService` を指していれば、Release を検証しているつもりでも launchd 側は Debug を起動します。修正は Release の LaunchAgent を再登録することです。

```sh
ConfigurationB/Scripts/install_launchagents.sh Release
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist" | grep ProgramArguments -A4
```
