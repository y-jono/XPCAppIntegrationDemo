# XPC 切り分け手順

この文書は Debug 成功 / Release 失敗を、コード、launchd、署名、Hardened Runtime、quarantine / App Translocation に分けて確認するためのコマンド集です。Apple Developer Program メンバーシップ期限切れのため Developer ID Application 証明書と Notarization は対象外です。Release は Apple Development / Team ID `EXAMPLE123` + Hardened Runtime で再現します。

## 1. Mach service 登録

named Mach service は launchd の `MachServices` に登録されている必要があります。未登録なら peer から lookup できません。

```sh
launchctl print "gui/$(id -u)/com.example.appA.service"
launchctl print "gui/$(id -u)/com.example.appB.service"
launchctl print "gui/$(id -u)/com.example.shared.service"
launchctl print "gui/$(id -u)" | grep -A5 -E 'com\.example\.(appA|appB|shared)'
```

失敗例:

```sh
launchctl print "gui/$(id -u)/com.example.appB.service"
# Could not find service "com.example.appB.service" in domain for uid ...
```

採否: これが失敗する場合、構成Aの 2接続は本質的に失敗します。`ConfigurationA/Scripts/install_launchagents.sh Debug` を実行して再登録します。

## 2. LaunchAgent の ProgramArguments パス

Release 失敗で最優先に見る項目です。plist が Debug の `.app/Contents/MacOS/<exec>` や古い DerivedData を指していないか確認します。

```sh
plutil -p "$HOME/Library/LaunchAgents/com.example.appA.service.plist"
plutil -p "$HOME/Library/LaunchAgents/com.example.appB.service.plist"
plutil -p "$HOME/Library/LaunchAgents/com.example.shared.service.plist"
ls -l /path/to/AppA.app/Contents/MacOS/AppA
plutil -extract CFBundlePackageType raw /path/to/AppA.app/Contents/Info.plist
codesign -dv --verbose=4 /path/to/AppA.app 2>&1
codesign -dv --verbose=4 /path/to/AppA.app/Contents/MacOS/AppA 2>&1
```

修正:

```sh
ConfigurationA/Scripts/build.sh Release
ConfigurationA/Scripts/install_launchagents.sh Release
launchctl kickstart -k "gui/$(id -u)/com.example.appA.service"
launchctl kickstart -k "gui/$(id -u)/com.example.appB.service"
```

## 3. bootstrap domain

同じ service 名でも `system`、`user/<uid>`、`gui/<uid>` は別 domain です。GUI アプリの LaunchAgent は通常 `gui/<uid>` へ登録します。

```sh
id -u
launchctl print "gui/$(id -u)/com.example.appA.service"
launchctl print "user/$(id -u)/com.example.appA.service" 2>&1 || true
sudo launchctl print "system/com.example.appA.service" 2>&1 || true
```

採否: `gui/<uid>` にだけ存在するなら、同じ login session の GUI/CLI から検証します。sudo や別ユーザーからの lookup は別問題です。

## 4. Bundle ID suffix と requirement

Debug は `com.example.AppA.Debug`、Release は `com.example.AppA` のように bundle id が変わります。本プロジェクトの pbxproj も差を明示しています。

```sh
codesign -dv --verbose=4 ConfigurationA/build/Debug/AppA.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -dv --verbose=4 ConfigurationA/build/Release/AppA.app 2>&1 | egrep 'Identifier|TeamIdentifier|Authority|Runtime'
codesign -d --entitlements :- ConfigurationA/build/Debug/AppA.app 2>/dev/null
codesign -d --entitlements :- ConfigurationA/build/Release/AppA.app 2>/dev/null
```

採否: `shouldAcceptNewConnection` で `identifier "..."` を固定しているなら、Debug/Release の両方を許す requirement にするか、Bundle ID を揃えます。

## 5. code signing requirement 拒否

本プロジェクトでは Release の `shouldAcceptNewConnection` 内で requirement 検証を行います。Debug は `#if DEBUG` でスキップします。

壊れた requirement。Release デフォルトで使われ、Apple Development 署名を拒否します。

```text
anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
```

正しい requirement。`BUILD_USE_CORRECT_REQUIREMENT=1` でビルドすると使われます。

```text
anchor apple generic and certificate leaf[subject.OU] = "EXAMPLE123"
```

```sh
log stream --style compact --predicate 'eventMessage CONTAINS "shouldAcceptNewConnection" OR eventMessage CONTAINS "署名検査" OR eventMessage CONTAINS "rejected"'
codesign -R='anchor apple generic' -v /path/to/AppA.app
codesign -R='certificate leaf[subject.OU] = "TEAMID"' -v /path/to/AppA.app
codesign -R='identifier "com.example.AppA"' -v /path/to/AppA.app
```

採否: Release で `requirement 不一致で拒否` が出れば、決定的再現は成功です。修正するには `BUILD_USE_CORRECT_REQUIREMENT=1` を付けて再ビルドします。

```sh
ConfigurationA/Scripts/build.sh Release
ConfigurationA/Scripts/install_launchagents.sh Release
ConfigurationA/Scripts/test_one_connection.sh Release
tail -f /tmp/com.example.appA.service.err.log /tmp/com.example.appB.service.err.log

BUILD_USE_CORRECT_REQUIREMENT=1 ConfigurationA/Scripts/build.sh Release
ConfigurationA/Scripts/install_launchagents.sh Release
ConfigurationA/Scripts/test_one_connection.sh Release
```

## 6. Hardened Runtime / entitlements

Release だけ `ENABLE_HARDENED_RUNTIME=YES` です。entitlements の差を確認します。

```sh
codesign -dv --verbose=4 /path/to/Release/AppA.app 2>&1 | egrep 'Runtime|flags|TeamIdentifier'
codesign -d --entitlements :- /path/to/Release/AppA.app 2>/dev/null
codesign -d --entitlements :- /path/to/Debug/AppA.app 2>/dev/null
```

採否: `get-task-allow` の有無、Library Validation、JIT、Apple Events などが通信相手のロードや補助処理に影響していないかを確認します。XPC lookup そのものは entitlement ではなく launchd 登録が前提です。

## 7. Quarantine / App Translocation

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

## 8. 同期 XPC 呼び出しの errorHandler

同期呼び出しは失敗点を見失いやすいので、必ず handler をログ化します。本プロジェクトでは `同期 proxy error:` を stderr に出します。

```sh
ConfigurationA/Scripts/test_one_connection.sh Debug 2>&1 | tee /tmp/xpc-a-test.log
ConfigurationB/Scripts/test_one_connection.sh Debug 2>&1 | tee /tmp/xpc-b-test.log
grep -E '同期 proxy error|interruption|invalidation|lookup|reply' /tmp/xpc-*.log
```

採否: error handler が出ずに停止する場合は、相手 process の stderr、LaunchAgent の `StandardErrorPath`、`log stream` を同時に見ます。

## Release 失敗を成功へ転じる手順

1. デフォルトの壊れた requirement のまま `ConfigurationA/Scripts/build.sh Release` または `ConfigurationB/Scripts/build.sh Release` を実行する。
3. `install_launchagents.sh Release` で plist を Release の `.app/Contents/MacOS/<exec>` 絶対パスへ再生成する。
4. `launchctl print gui/$(id -u)/...` で `program` と `MachServices` を確認する。
5. `codesign -dv --verbose=4` と `codesign -d --entitlements :-` で Debug/Release 差を確認する。
6. `log stream` と `/tmp/com.example.*.err.log` を見ながら test script を実行する。
7. requirement 拒否を確認したら、`BUILD_USE_CORRECT_REQUIREMENT=1` を付けて再ビルドし、Team ID `EXAMPLE123` の requirement に切り替える。

## Debug パス事故の再現

原因 #2 は LaunchAgent が Debug の `.app` を指したままになる事故です。

```sh
ConfigurationA/Scripts/build.sh Debug
ConfigurationA/Scripts/install_launchagents.sh Debug
plutil -p "$HOME/Library/LaunchAgents/com.example.appA.service.plist" | grep ProgramArguments -A4

ConfigurationA/Scripts/build.sh Release
ConfigurationA/Scripts/test_one_connection.sh Release
```

この時点で plist が `build/Debug/AppA.app/Contents/MacOS/AppA` を指していれば、Release を検証しているつもりでも launchd 側は Debug を起動します。修正は Release の LaunchAgent を再登録することです。

```sh
ConfigurationA/Scripts/install_launchagents.sh Release
plutil -p "$HOME/Library/LaunchAgents/com.example.appA.service.plist" | grep ProgramArguments -A4
```
