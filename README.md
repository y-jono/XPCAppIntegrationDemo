# XPCAppIntegrationDemo

macOS の `NSConnection` 風の対称 P2P 通信を `NSXPCConnection` へ移行するときに、Debug では成功し Release では失敗する問題を切り分けるための最小再現プロジェクトです。`SharedService.app` だけが listener を持ち、`AppA.app` / `AppB.app` はクライアントとして接続する、Apple の XPC 標準形に近い構成です。各ターゲットは LSUIElement の `.app` バンドルとして生成されます。実装は Swift ですが、失敗要因は Objective-C 固有ではありません。主因は launchd の Mach service 登録、LaunchAgent の `.app/Contents/MacOS/<exec>` パス、署名、Hardened Runtime、bootstrap domain の差であり、言語非依存です。

各 `.app` の起動部は `NSApplicationDelegate.applicationDidFinishLaunching(_:)` で listener resume / peer 呼び出しを行う AppKit ライフサイクルに載せ替えています。

> 本書や `DIAGNOSIS.md` の用語（XPC / launchd / Mach service / コード署名 / Hardened Runtime など）が分からない場合は、先に [PRIMER.md](PRIMER.md)（前提知識ゼロから読める入門ガイド）を読んでください。

## セットアップ: 自分の署名で動かす（重要）

このリポジトリ中の署名値は **架空のプレースホルダ**です。`Debug` は ad-hoc 署名なので置換不要でビルド・実行できますが、`Release` ビルドと失敗再現を実際に動かすには、以下を**あなた自身の値**へ置換してください。

| プレースホルダ | 意味 | あなたの値の調べ方 |
|---|---|---|
| `EXAMPLE123` | Team ID（10桁英数字） | `security find-identity -v -p codesigning` で出る証明書名の括弧内 OU、または developer.apple.com → Account → Membership |
| `Example Developer (CERT123456)` | 署名 identity 名（説明用の例） | 同上。実際の identity 名に読み替え |

置換する場所:

1. **pbxproj の `DEVELOPMENT_TEAM`**（`EXAMPLE123` → あなたの Team ID）
   - `ConfigurationB/XPCAppIntegrationB.xcodeproj/project.pbxproj`

一括置換の例（あなたの Team ID を `ABCDE12345` と仮定）:

```sh
grep -rl 'EXAMPLE123' --include='*.pbxproj' . \
  | xargs perl -pi -e 's/EXAMPLE123/ABCDE12345/g'
```



署名 identity は Xcode の Automatic 署名（`CODE_SIGN_IDENTITY = "Apple Development"` + `DEVELOPMENT_TEAM`）で解決されます。Developer ID をお持ちなら `CODE_SIGN_IDENTITY` をそれに変え、`ENABLE_HARDENED_RUNTIME=YES` のまま Notarization まで試せます。

## 構成

- `ConfigurationB/`: `SharedService.app` だけが `NSXPCListener(machServiceName:)` を持ち、`AppA.app` / `AppB.app` はクライアントとして接続する構成。Mach service は `com.example.shared.service`。
- `LaunchAgents/`: `~/Library/LaunchAgents/` にインストールする plist テンプレート。
- `Scripts/`: build、LaunchAgent install、疎通確認スクリプト。

## ビルド

Debug は ad-hoc 署名でそのままビルドできます。

```sh
ConfigurationB/Scripts/build.sh Debug
```

ビルドスクリプトは `build/<Configuration>/*.app` の存在、`Contents/MacOS/<exec>` の実行可能性、`Contents/Info.plist` の `CFBundlePackageType=APPL` を確認します。

Release は Apple Developer Program メンバーシップ期限切れの前提で、手元の `Apple Development: Example Developer (CERT123456)` / Team ID `EXAMPLE123` に設定しています。Developer ID Application 証明書は使いません。Release のみ `ENABLE_HARDENED_RUNTIME=YES` です。Debug は引き続き ad-hoc の Sign to Run Locally です。

Bundle ID は Debug は `.Debug` suffix あり、Release は suffix なしです。

```text
Debug:   com.example.shared.service.Debug
Release: com.example.shared.service
```

## LaunchAgent 登録と実行

`install_launchagents.sh` はテンプレート中の `__BUILD_PRODUCTS__` を現在の `build/<Configuration>` に置換し、`ProgramArguments` が `SharedService.app/Contents/MacOS/SharedService` のような `.app` 内 executable を指す plist を `~/Library/LaunchAgents/` へ配置して `launchctl bootstrap gui/$(id -u)` します。スクリプト経由でのみホーム配下を書き換えます。

```sh
ConfigurationB/Scripts/install_launchagents.sh Debug
ConfigurationB/Scripts/test_scenario.sh Debug
```

疎通確認は `test_scenario.sh` に一本化しています。引数を省略すると `normal`（AppB→AppA の順で起動する基本の正常系）1本だけを実行します。SharedService/AppA/AppB の起動順序や異常系まで含めてまとめて検証したい場合は `scenario` に `all` を指定してください。

```sh
ConfigurationB/Scripts/test_scenario.sh Debug all
```

シナリオを個別に指定することもできます（`normal` / `reverse-order` / `simultaneous` / `peer-absent` / `no-shared-service`）。各シナリオはログを `grep` して自動で PASS/FAIL 判定します。`no-shared-service` は検証のために SharedService の LaunchAgent を一時的に登録解除しますが、実行後に自動で再登録します。各プロセスの生ログはそのまま stdout にも出るため、`test_scenario.sh Debug normal 2>&1 | tee /tmp/xpc-b-test.log` のように `tee` して従来通りログを確認・grep することもできます。

テスト実行後に AppA/AppB/SharedService のプロセスが残ってしまった場合は、後片付け専用の `cleanup_processes.sh` で終了できます（`test_scenario.sh` は末尾で自動的にこれを呼びます）。

```sh
ConfigurationB/Scripts/cleanup_processes.sh
```

## AppA / AppB 間の相互通信（push）

SharedService は接続してきた client を `register(clientName:)` で名前登録し、`send(_:withReply:)` が呼ばれた瞬間に対象 client の `remoteObjectProxy`（`ClientCallbackProtocol`）へ即座に push します。mailbox のような永続化はしていないため、相手が接続中でなければ `delivered=false` が返り、そのメッセージは失われます。

やり取りするオブジェクトは `GreetingCard`（`from` / `to` / `text` を持つ `NSSecureCoding` 準拠の自作クラス、[Shared/Sources/SharedProtocol.swift](ConfigurationB/Shared/Sources/SharedProtocol.swift)）です。AppA/AppB はどちらも起動すると

1. `register(clientName:)` で自分の名前を登録する
2. 0.5秒待ってから（相手がまだ register 中の可能性があるため）相手宛てに `GreetingCard` を `send` する
3. 「自分の送信が完了」かつ「相手からの push を受信」の両方が揃うか、最大2秒のタイムアウトのどちらか早い方で終了する

という一発モデルで動作し、常駐GUIアプリ化はしていません。push を受け取った瞬間に即終了すると自分の送信がまだの場合に打ち切ってしまうため、両方揃うまでは終了しないようにしています。push は相手が同時に接続していないと届かないため、`test_scenario.sh` の `normal` シナリオは AppB を先にバックグラウンド起動して `register` 完了を待ってから AppA を起動します。

```sh
"$ROOT/build/$CONFIGURATION/AppB.app/Contents/MacOS/AppB" &
sleep 0.3
"$ROOT/build/$CONFIGURATION/AppA.app/Contents/MacOS/AppA"
```

## Release ビルドの確認

```sh
ConfigurationB/Scripts/build.sh Release
ConfigurationB/Scripts/install_launchagents.sh Release
ConfigurationB/Scripts/test_scenario.sh Release
```

原因 #2 の再現は、Debug の LaunchAgent を登録したまま Release をビルドしてテストします。`~/Library/LaunchAgents/*.plist` の `ProgramArguments` が `build/Debug/*.app/Contents/MacOS/...` を指したままなら、Release を実行しているつもりでも launchd は Debug の `.app` を起動します。修正は `install_launchagents.sh Release` を再実行して Release の絶対パスへ更新することです。

ログは stderr と LaunchAgent の `StandardErrorPath` に出ます。

```sh
tail -f /tmp/com.example.shared.service.err.log
log stream --style compact --predicate 'process == "launchd" OR eventMessage CONTAINS "com.example"'
```

`.app` の基本確認:

```sh
ls -ld ConfigurationB/build/Debug/SharedService.app
plutil -p ConfigurationB/build/Debug/SharedService.app/Contents/Info.plist
plutil -extract CFBundlePackageType raw ConfigurationB/build/Debug/SharedService.app/Contents/Info.plist
```

## アーキテクチャ評価

`SharedService.app` だけが `NSXPCListener(machServiceName:)` を持ち、`AppA.app` / `AppB.app` はクライアントとして `NSXPCConnection(machServiceName:)` で接続する構成です。これは Apple の XPC 標準形（明確な vendor が listener を持ち、client が接続する）に近く、NSConnection の対称 P2P からの移行先として安定します。

GUI アプリ自身が named Mach service を vend する設計は避け、専用の `.app`（本デモでは `SharedService.app`）を vendor に据えています。LaunchAgent が起動するプロセスとユーザーが Finder から起動する `.app` が二重起動したり、GUI ライフサイクルと launchd の on-demand ライフサイクルがずれたりする事故を避けやすくなります。Release でだけ壊れる場合、コードの問題ではなく、LaunchAgent が古い Debug の `.app/Contents/MacOS/<exec>` や translocation されたパスを指しているだけ、という事故が多くなります。

NSConnection の対称 P2P 構成をそのまま XPC へ移すと、Release 脆弱性の温床になります。Debug では同一 DerivedData、緩い署名、同じ起動コンテキストで偶然通り、Release では Hardened Runtime、LaunchAgent の絶対パスが表面化します。

## Debug 成功 / Release 失敗の優先原因

1. named Mach service 未登録: `NSXPCListener(machServiceName:)` の名前は launchd の `MachServices` に登録されて初めて peer から lookup 可能です。`SharedService` に LaunchAgent が本質的に必要です。
2. LaunchAgent の `ProgramArguments` が Debug の `.app/Contents/MacOS/<exec>` を指したまま: Release をビルドしても launchd が古い Debug バンドル内 executable を起動していると、署名や protocol が不一致になります。
3. bootstrap domain の差: `gui/501` に登録した service を別 UID、別 login session、root domain から lookup しても見えません。
4. Hardened Runtime / entitlements 差: `get-task-allow`、Library Validation、必要 entitlement の差が Release だけの挙動差になります。
5. Notarization / quarantine / App Translocation: 今回はメンバーシップ無効のため Notarization は対象外です。quarantine 付き `.app` を未移動で起動すると `/private/var/folders/.../AppTranslocation/...` 配下へ実行パスがランダム化され、LaunchAgent の絶対パス前提が崩れます。
6. 同期呼び出しのログ不足: `synchronousRemoteObjectProxyWithErrorHandler` は error handler を必ずログ化しないと、本当の失敗理由を見失います。

具体的な切り分けコマンドは [DIAGNOSIS.md](DIAGNOSIS.md) を参照してください。

## Notarization / Quarantine / Translocation

Developer Program メンバーシップが無効なため Notarization は対象外です。quarantine や Gatekeeper の観察は `.app` 単位で行います。

```sh
xattr -lr /path/to/SharedService.app | grep -i quarantine || true
xattr -d com.apple.quarantine /path/to/SharedService.app 2>/dev/null || true
spctl --assess --type execute --verbose=4 /path/to/SharedService.app
codesign --verify --deep --strict --verbose=4 /path/to/SharedService.app
```

translocation が疑わしい場合は、起動中プロセスの実行パスを見ます。

```sh
pgrep -fl SharedService
ps -axo pid,comm,args | grep -E 'AppA|AppB|SharedService'
log stream --style compact --predicate 'eventMessage CONTAINS "AppTranslocation" OR eventMessage CONTAINS "com.example"'
```

`/private/var/folders/.../AppTranslocation/.../d/SharedService.app/Contents/MacOS/SharedService` のようなパスが出る場合、LaunchAgent の固定パスと実行実体がずれます。正式なインストール先に配置し、quarantine を解除または notarization 済み配布にしてから LaunchAgent を再生成してください。

## 推奨形

NSConnection から XPC へ移行する場合は、対称 P2P を温存せず、単一 vendor を決めます。GUI アプリ間で直接 listener を持ち合うより、LaunchAgent または XPC service（本デモでは `SharedService.app`）を明示的な broker/vendor とし、`AppA` / `AppB` は client へ寄せます。
