# XPCAppIntegrationDemo

Debug ビルドでは動くのに Release ビルドでは失敗する XPC 通信を、手元で再現するためのサンプルプロジェクトです。

macOS の古い通信方式 `NSConnection`（2 つのアプリが対等にやり取りする形）を、後継の `NSXPCConnection`（XPC）へ移すと、Debug では通っていた通信が Release で止まることがあります。原因はコードそのものではなく、アプリの登録・署名・起動パスといった macOS 側の設定差にあります。本プロジェクトはその失敗を最小構成で再現します。

構成は Apple が想定する標準的な形にしてあります。`SharedService.app` だけが接続を待ち受け（listener）、`AppA.app` / `AppB.app` はそこへ接続するクライアントです。各アプリは UI を持たない常駐タイプ（Dock に出ない `LSUIElement` の `.app`）としてビルドされます。実装は Swift ですが、失敗の要因は言語に依存しません。

> **XPC / launchd / コード署名などの用語が分からない場合は、先に [PRIMER.md](PRIMER.md) を読んでください。** 前提知識ゼロから読める入門ガイドです。本 README と [DIAGNOSIS.md](DIAGNOSIS.md) は、その用語を知っている前提で書いています。

## セットアップ: 自分の署名で動かす

このリポジトリに書かれている署名の値は、すべて**サンプル値（架空のプレースホルダ）**です。

- **Debug ビルド**は ad-hoc 署名（チーム情報を持たないローカル専用の署名）なので、値を置き換えなくてもビルド・実行できます。
- **Release ビルド**を動かすには、以下を**あなた自身の値**に置き換えてください。

| プレースホルダ | 意味 | 調べ方 |
|---|---|---|
| `EXAMPLE123` | Team ID（開発者アカウントごとの 10 桁の英数字） | ターミナルで `security find-identity -v -p codesigning` を実行し、証明書名の括弧内に出る値。または developer.apple.com → Account → Membership |
| `Example Developer (CERT123456)` | 署名 identity の名前（説明用のサンプル） | 上と同じ。実際の identity 名に読み替え |

置き換える場所は `project.pbxproj` の `DEVELOPMENT_TEAM`（`EXAMPLE123` → あなたの Team ID）です。

- `ConfigurationB/XPCAppIntegrationB.xcodeproj/project.pbxproj`

一括で置き換える例（あなたの Team ID を `ABCDE12345` とした場合）:

```sh
grep -rl 'EXAMPLE123' --include='*.pbxproj' . \
  | xargs perl -pi -e 's/EXAMPLE123/ABCDE12345/g'
```

### 署名設定の要点

- 署名は Xcode の自動署名で解決されます（`CODE_SIGN_IDENTITY = "Apple Development"` と `DEVELOPMENT_TEAM` の組み合わせ）。
- Debug は ad-hoc 署名、Release は Apple Development 署名 + Hardened Runtime（追加のセキュリティ制限）です。
- Developer ID Application 証明書（App Store 外への配布用）は使いません。持っている場合は `CODE_SIGN_IDENTITY` をそれに変えれば、Notarization（Apple の公証）まで試せます。

## プロジェクトの構成

- `ConfigurationB/`: `SharedService.app` だけが listener を持ち、`AppA.app` / `AppB.app` はそこへ接続するクライアントになる構成。Mach サービス名は `com.example.shared.service`。
- `LaunchAgents/`: `~/Library/LaunchAgents/` に置く plist（登録用の設定ファイル）のテンプレート。
- `Scripts/`: ビルド、LaunchAgent 登録、通信テストのスクリプト。

## ビルド

Debug は ad-hoc 署名でそのままビルドできます。

```sh
ConfigurationB/Scripts/build.sh Debug
```

ビルドスクリプトは、`build/<Configuration>/*.app` が生成されたか、`Contents/MacOS/<exec>` が実行可能か、`Contents/Info.plist` の `CFBundlePackageType` が `APPL` かを確認します。

Debug と Release では、失敗を再現するために次の設定を意図的に変えてあります。

| 項目 | Debug | Release |
|---|---|---|
| 署名 | ad-hoc | Apple Development（Team ID `EXAMPLE123`） |
| Hardened Runtime | 無効 | 有効 |
| Bundle ID | `com.example.shared.service.Debug`（末尾に `.Debug`） | `com.example.shared.service` |

## LaunchAgent の登録と実行

`install_launchagents.sh` は次の処理をまとめて行います。

1. テンプレートの `__BUILD_PRODUCTS__` を、いま使っている `build/<Configuration>` のパスに置き換える。
2. その plist を `~/Library/LaunchAgents/` に置く。plist の `ProgramArguments` は `SharedService.app/Contents/MacOS/SharedService` のように `.app` 内の実行ファイルを指します。
3. `launchctl bootstrap gui/$(id -u)` で登録する。

ホームディレクトリ配下を書き換えるのは、このスクリプト経由だけです。

```sh
ConfigurationB/Scripts/install_launchagents.sh Debug
ConfigurationB/Scripts/test_scenario.sh Debug
```

通信テストは `test_scenario.sh` に一本化しています。

- 引数なし → `normal`（AppB → AppA の順で起動する基本の正常系）だけを実行します。
- `all` を付けると、起動順序や異常系まで含めてまとめて検証します。
- 個別のシナリオも指定できます（`normal` / `reverse-order` / `simultaneous` / `peer-absent` / `no-shared-service`）。

各シナリオはログを `grep` して自動で PASS / FAIL を判定します。`no-shared-service` は検証のため SharedService の LaunchAgent を一時的に外しますが、実行後に自動で登録し直します。

```sh
ConfigurationB/Scripts/test_scenario.sh Debug all
```

各プロセスの生ログは stdout にも出るので、`test_scenario.sh Debug normal 2>&1 | tee /tmp/xpc-b-test.log` のように `tee` で保存して `grep` できます。テスト後に AppA / AppB / SharedService のプロセスが残った場合は、後片付け用の `cleanup_processes.sh` で終了できます（`test_scenario.sh` は末尾で自動的に呼びます）。

```sh
ConfigurationB/Scripts/cleanup_processes.sh
```

## AppA / AppB の相互通信（push）

AppA と AppB は SharedService を経由してメッセージを送り合います。

- SharedService は接続してきたクライアントを `register(clientName:)` で名前登録します。
- クライアントが `send(_:withReply:)` を呼ぶと、SharedService はその瞬間に宛先クライアントの受信用オブジェクト（`ClientCallbackProtocol` の `receive`）を呼び出します（push）。
- メッセージをためておく仕組み（mailbox）はありません。宛先が接続中でなければ `delivered=false` が返り、そのメッセージは失われます。

やり取りするデータは `GreetingCard`（`from` / `to` / `text` を持つ自作クラス。[SharedProtocol.swift](ConfigurationB/Shared/Sources/SharedProtocol.swift)）です。AppA / AppB は起動すると次のように動きます。

1. `register(clientName:)` で自分の名前を登録する。
2. 0.5 秒待ってから（相手がまだ登録中かもしれないため）、相手宛てに `GreetingCard` を送る。
3. 「自分の送信完了」と「相手からの受信」の両方がそろうか、最大 2 秒でタイムアウトするか、早い方で終了する。

この一発モデルで動作し、常駐 GUI アプリにはしていません。push は相手が同時に接続していないと届かないため、`normal` シナリオは AppB を先に起動して登録の完了を待ってから AppA を起動します。

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

## ログの見方

失敗の理由は、まず SharedService（listener 側）のログに出ます。

```sh
tail -f /tmp/com.example.shared.service.err.log

# システム全体のログをリアルタイム表示
log stream --style compact --predicate 'process == "launchd" OR eventMessage CONTAINS "com.example"'
```

`.app` の基本確認:

```sh
ls -ld ConfigurationB/build/Debug/SharedService.app
plutil -p ConfigurationB/build/Debug/SharedService.app/Contents/Info.plist
plutil -extract CFBundlePackageType raw ConfigurationB/build/Debug/SharedService.app/Contents/Info.plist
```

## Debug と Release でだけ挙動が変わる原因

「Debug は通るのに Release だけ失敗する」原因はいくつかあります。このプロジェクトのアプリはコード側で接続を拒否しないため、失敗はすべて**環境の違い**（登録・パス・配布状態）から起きます。最初に疑うべき代表例は次の 3 つです。原因の一覧と切り分けコマンドは [DIAGNOSIS.md](DIAGNOSIS.md) にまとめています。

1. **Mach サービス名が launchd に未登録** — listener を作っても、LaunchAgent で登録していなければ相手から見つけられません。SharedService には LaunchAgent 登録が必須です。
2. **LaunchAgent が古い Debug ビルドを指したまま** — Release をビルドしても、plist のパスが `build/Debug/...` を指していると launchd は Debug の `.app` を起動します。最も多い原因です。
3. **bootstrap domain の違い** — `gui/501` に登録したサービスを、別ユーザーや別セッション、root から探しても見つかりません。

「Debug の LaunchAgent を登録したまま Release をビルドしてテストする」と原因 2 を再現できます。plist の `ProgramArguments` が `build/Debug/*.app/...` を指したままなら、Release を実行しているつもりでも launchd は Debug を起動します。`install_launchagents.sh Release` を再実行して Release の絶対パスに更新すれば解消します。

## 移行の推奨形

`NSConnection` から XPC へ移すときは、両アプリが対等に listener を持ち合う形を避け、**listener を持つ側を 1 つに決める**のが安定します。

GUI アプリ自身が Mach サービスを提供する設計は避け、本デモのように専用の `.app`（`SharedService.app`）を提供役（vendor）に据えます。こうすると、LaunchAgent が起動するプロセスと Finder から起動した `.app` が二重に立ち上がったり、GUI の起動タイミングと launchd のオンデマンド起動がずれたりする問題を避けやすくなります。双方向の通信が必要でも、本デモのように提供役を 1 つ挟めば実現できます。

## Notarization / quarantine / App Translocation

Apple Developer Program メンバーシップが期限切れの前提のため、Notarization（公証）は扱いません。quarantine（ダウンロード由来の印）や Gatekeeper の確認は `.app` 単位で行います。

```sh
xattr -lr /path/to/SharedService.app | grep -i quarantine || true
xattr -d com.apple.quarantine /path/to/SharedService.app 2>/dev/null || true
spctl --assess --type execute --verbose=4 /path/to/SharedService.app
codesign --verify --deep --strict --verbose=4 /path/to/SharedService.app
```

quarantine が残った `.app` を移動せずに起動すると、実行パスが `/private/var/folders/.../AppTranslocation/...` に変わることがあります（App Translocation）。LaunchAgent は固定パスを前提にしているため、この状態だと起動対象を見失います。`.app` を `/Applications` などへ移動し、quarantine を外してから LaunchAgent を登録し直してください。

```sh
pgrep -fl SharedService
ps -axo pid,comm,args | grep -E 'AppA|AppB|SharedService'
log stream --style compact --predicate 'eventMessage CONTAINS "AppTranslocation" OR eventMessage CONTAINS "com.example"'
```
