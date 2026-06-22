# XPCAppIntegrationDemo

macOS の `NSConnection` 風の対称 P2P 通信を `NSXPCConnection` へ移行するときに、Debug では成功し Release では失敗する問題を切り分けるための最小再現プロジェクトです。各ターゲットは LSUIElement の `.app` バンドルとして生成されます。実装は Swift ですが、失敗要因は Objective-C 固有ではありません。主因は launchd の Mach service 登録、LaunchAgent の `.app/Contents/MacOS/<exec>` パス、署名、Hardened Runtime、Notarization、bootstrap domain の差であり、言語非依存です。

各 `.app` の起動部は `NSApplicationDelegate.applicationDidFinishLaunching(_:)` で listener resume / peer 呼び出しを行う AppKit ライフサイクルに載せ替えています。

## 構成

- `ConfigurationA/`: `AppA.app` と `AppB.app` の双方が `NSXPCListener(machServiceName:)` を持つ構成。Mach service は `com.example.appA.service` / `com.example.appB.service`。
- `ConfigurationB/`: `SharedService.app` だけが `NSXPCListener(machServiceName:)` を持ち、`AppA.app` / `AppB.app` はクライアントとして接続する構成。Mach service は `com.example.shared.service`。
- 各構成に `--variant=one-connection` と `--variant=two-connection` の観察用バリアントがあります。
- `LaunchAgents/`: `~/Library/LaunchAgents/` にインストールする plist テンプレート。
- `Scripts/`: build、LaunchAgent install、疎通確認スクリプト。

## ビルド

Debug は ad-hoc 署名でそのままビルドできます。

```sh
ConfigurationA/Scripts/build.sh Debug
ConfigurationB/Scripts/build.sh Debug
```

ビルドスクリプトは `build/<Configuration>/*.app` の存在、`Contents/MacOS/<exec>` の実行可能性、`Contents/Info.plist` の `CFBundlePackageType=APPL` を確認します。

Release は Developer ID 署名を想定しています。`project.pbxproj` の `PLACEHOLDER_TEAM_ID` と `Developer ID Application: PLACEHOLDER` を実際の Team ID / 証明書名に置換してください。検証だけ ad-hoc Release にしたい場合は、`xcodebuild ... CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` のように一時上書きします。ただし、この場合は Developer ID + Hardened Runtime の問題再現にはなりません。

## LaunchAgent 登録と実行

`install_launchagents.sh` はテンプレート中の `__BUILD_PRODUCTS__` を現在の `build/<Configuration>` に置換し、`ProgramArguments` が `AppA.app/Contents/MacOS/AppA` のような `.app` 内 executable を指す plist を `~/Library/LaunchAgents/` へ配置して `launchctl bootstrap gui/$(id -u)` します。スクリプト経由でのみホーム配下を書き換えます。

```sh
ConfigurationA/Scripts/install_launchagents.sh Debug
ConfigurationA/Scripts/test_one_connection.sh Debug
ConfigurationA/Scripts/test_two_connection.sh Debug

ConfigurationB/Scripts/install_launchagents.sh Debug
ConfigurationB/Scripts/test_one_connection.sh Debug
ConfigurationB/Scripts/test_two_connection.sh Debug
```

ログは stderr と LaunchAgent の `StandardErrorPath` に出ます。

```sh
tail -f /tmp/com.example.appA.service.err.log
tail -f /tmp/com.example.appB.service.err.log
tail -f /tmp/com.example.shared.service.err.log
log stream --style compact --predicate 'process == "launchd" OR eventMessage CONTAINS "com.example"'
```

`.app` の基本確認:

```sh
ls -ld ConfigurationA/build/Debug/AppA.app
plutil -p ConfigurationA/build/Debug/AppA.app/Contents/Info.plist
plutil -extract CFBundlePackageType raw ConfigurationA/build/Debug/AppA.app/Contents/Info.plist
```

## アーキテクチャ評価

双方が `NSXPCListener(machServiceName:)` と `NSXPCConnection(machServiceName:)` を持つ構成は、NSConnection の対称 P2P をそのまま XPC に写経した形です。技術的には実装できますが、named Mach service は launchd の `MachServices` 登録が前提なので、各アプリを単に起動しただけでは peer から `bootstrap_look_up` できません。Apple の XPC の標準形に近いのは、明確な vendor が listener を持ち、client が接続する構成です。

GUI アプリ自身が named Mach service を vend する設計は注意が必要です。LaunchAgent が起動するプロセスとユーザーが Finder から起動する `.app` が二重起動したり、GUI ライフサイクルと launchd の on-demand ライフサイクルがずれたりします。Release でだけ壊れる場合、コードの問題ではなく、LaunchAgent が古い Debug の `.app/Contents/MacOS/<exec>` や translocation されたパスを指しているだけ、という事故が多くなります。

1接続双方向は、1本の `NSXPCConnection` に `exportedInterface` と `remoteObjectInterface` を両方設定し、client から server へ接続したあと server 側が client の exported object を呼び返す形です。この場合、片側だけ listener を持てば済み、XPC の vendor/client モデルに近いです。2接続は双方が listener を持つため、Mach service 登録、署名要件、bootstrap domain、ライフサイクルの失敗点が倍になります。

NSConnection の対称 P2P 構成をそのまま XPC へ移すと、Release 脆弱性の温床になります。Debug では同一 DerivedData、緩い署名、同じ起動コンテキストで偶然通り、Release では Developer ID、Hardened Runtime、Notarization、LaunchAgent の絶対パス、code requirement が表面化します。

## Debug 成功 / Release 失敗の優先原因

1. named Mach service 未登録: `NSXPCListener(machServiceName:)` の名前は launchd の `MachServices` に登録されて初めて peer から lookup 可能です。構成Aは AppA/AppB の両方に LaunchAgent が本質的に必要です。
2. LaunchAgent の `ProgramArguments` が Debug の `.app/Contents/MacOS/<exec>` を指したまま: Release をビルドしても launchd が古い Debug バンドル内 executable を起動していると、署名や protocol が不一致になります。
3. bootstrap domain の差: `gui/501` に登録した service を別 UID、別 login session、root domain から lookup しても見えません。
4. code signing requirement の不一致: `shouldAcceptNewConnection` で Team ID、bundle id、anchor を検査している場合、Apple Development と Developer ID の差、Debug suffix `.debug` の有無で拒否されます。
5. Hardened Runtime / entitlements 差: `get-task-allow`、Library Validation、必要 entitlement の差が Release だけの挙動差になります。
6. Notarization / quarantine / App Translocation: quarantine 付き `.app` を未移動で起動すると `/private/var/folders/.../AppTranslocation/...` 配下へ実行パスがランダム化され、LaunchAgent の絶対パス前提が崩れます。
7. Bundle ID suffix と Mach service 名/requirement の食い違い: Debug の `.debug` suffix を許す requirement で Release を拒否、または逆が起きます。
8. 同期呼び出しのログ不足: `synchronousRemoteObjectProxyWithErrorHandler` は error handler を必ずログ化しないと、本当の拒否理由を見失います。

具体的な切り分けコマンドは [DIAGNOSIS.md](/Users/yoshinori/ghq/github.com/y-jono/XPCAppIntegrationDemo/DIAGNOSIS.md) を参照してください。

## Listener 主体の判別

「アプリが直接 Listener を立てる」構成は `ConfigurationA` です。`AppA.app` と `AppB.app` の各 executable が `NSXPCListener(machServiceName:)` を作成します。これは GUI アプリへ適用すると、GUI プロセスが service vendor も兼ねる設計になります。

「XPCサービス/エージェントが Listener を立てる」構成は `ConfigurationB` です。`SharedService.app` が listener を持ち、`AppA.app` / `AppB.app` は `NSXPCConnection(machServiceName:)` で接続するだけです。Release/Notarization 前提ではこの形が安定しやすく、NSConnection からの移行先として推奨です。

## Notarization / Quarantine / Translocation

Release 配布物では `.app` 単位で確認します。

```sh
xattr -lr /path/to/AppA.app | grep -i quarantine || true
xattr -d com.apple.quarantine /path/to/AppA.app 2>/dev/null || true
spctl --assess --type execute --verbose=4 /path/to/AppA.app
codesign --verify --deep --strict --verbose=4 /path/to/AppA.app
```

translocation が疑わしい場合は、起動中プロセスの実行パスを見ます。

```sh
pgrep -fl AppA
ps -axo pid,comm,args | grep -E 'AppA|AppB|SharedService'
log stream --style compact --predicate 'eventMessage CONTAINS "AppTranslocation" OR eventMessage CONTAINS "com.example"'
```

`/private/var/folders/.../AppTranslocation/.../d/AppA.app/Contents/MacOS/AppA` のようなパスが出る場合、LaunchAgent の固定パスと実行実体がずれます。正式なインストール先に配置し、quarantine を解除または notarization 済み配布にしてから LaunchAgent を再生成してください。

## 推奨形

NSConnection から XPC へ移行する場合は、対称 P2P を温存せず、単一 vendor を決めます。GUI アプリ間で直接 listener を持ち合うより、LaunchAgent または XPC service を明示的な broker/vendor とし、AppA/AppB は client へ寄せます。双方向通知が必要なら、client 接続時に `exportedInterface` を渡して callback させる 1接続双方向を優先します。2接続は、独立したライフサイクルと権限境界が本当に必要な場合に限定してください。
