# 入門ガイド — README / DIAGNOSIS を読むための前提知識

`README.md` と `DIAGNOSIS.md` に出てくる用語を、前提知識なしで理解するための解説です。XPC・launchd・コード署名を知らなくても、上から順に読めば 2 つのドキュメントが読めるようになることを目指します。

このガイドでは、理解を助けるために「電話」のたとえを使います。技術用語には対応するたとえを添えますが、正式な用語も併記するので、読み終えたらたとえは忘れて構いません。

> **読む順番の目安**
> - README の前半を読みたい → まず 1〜4
> - 署名まわりを読みたい → 5〜8
> - 原因リストと診断コマンドを読みたい → 9〜12
> - 急ぐなら 11（用語集）と 12（コマンドの読み方）だけ先に見ても構いません。

---

## 0. この問題を一言で

> **2 つのアプリ（AppA / AppB）が SharedService を通じて通信する。Debug ビルドでは通信できるのに、Release ビルドではできない。なぜか。**

たとえで言うと、通信の仕組みが **XPC**（電話）、相手を見つける仕組みが **launchd / Mach サービス**（電話帳）、相手が本物かを確かめる仕組みが **コード署名**（本人確認）です。Debug と Release ではこれらの条件が少しずつ変わるため、Release だけ通信に失敗することがあります。

---

## 1. 前提: プロセスとプロセス間通信（IPC）

- **プロセス** = 実行中のアプリ 1 つ。AppA と AppB は別プロセス、つまり別々のメモリ空間で動く独立したプログラムです。
- 別プロセスどうしは、相手の関数を直接呼べません。間に「通信」の仕組みが必要です。これが **IPC（Inter-Process Communication、プロセス間通信）**。
- 昔の macOS は **NSConnection** という IPC を使っていましたが、非推奨（deprecated）になりました。後継が **XPC**（`NSXPCConnection`）です。
- このプロジェクトは「NSConnection から XPC に移したら Release で動かなくなった」という移行トラブルの再現です。

---

## 2. XPC の基本

XPC は「相手プロセスのオブジェクトを、手元のオブジェクトのように呼ぶ」仕組みです。登場人物は 3 つ。

| 用語 | 役割 | たとえ |
|---|---|---|
| **`NSXPCListener`** | 接続を待ち受ける側（サーバー役） | 電話を受ける人 |
| **`NSXPCConnection`** | 接続をかける側（クライアント役） | 電話をかける人 |
| **proxy（代理オブジェクト）** | 相手のオブジェクトの代わり。これを呼ぶと相手側で処理が動く | 受話器 |

### インターフェース（何を呼べるかの取り決め）

呼び出せるメソッドの一覧を、あらかじめ両者で決めておきます。それが **protocol**（`@objc` を付けて Objective-C 互換にします）。接続には 2 つの向きがあります。

- **`remoteObjectInterface`**: 相手が提供する機能。自分が呼び出す側の取り決め。
- **`exportedInterface` + `exportedObject`**: 自分が提供する機能と、その実体オブジェクト。相手から呼ばれる側の取り決め。

> 例（本プロジェクトの AppA）: `remoteObjectInterface` に SharedService の機能（`register` / `send`）を設定して呼び出す一方、`exportedInterface` + `exportedObject` に「push を受け取る」機能（`receive`）を設定しておきます。SharedService は AppA が `send` した瞬間、宛先クライアントの接続に向けて `receive` を呼び返します。1 本の接続の中で「呼ぶ」と「呼ばれる」が両方成り立っているのがポイントです。

### 接続の状態を知るハンドラ（ログで重要）

- **`shouldAcceptNewConnection`**: listener 側で「この接続を受けるか」を判断する場所。相手の署名を検査して拒否することもできます（本プロジェクトは検査せず、すべて受け入れます）。
- **`interruptionHandler`**: 相手プロセスが落ちるなどして接続が一時中断したときに呼ばれます。
- **`invalidationHandler`**: 接続が完全に無効化されたときに呼ばれます。
- **`synchronousRemoteObjectProxyWithErrorHandler`**: 返事が来るまで待つ同期呼び出しで proxy を取ります。失敗理由は `errorHandler` に渡されます。**これをログに出さないと失敗理由を確認できない**ため、診断ではもっとも重要です。

---

## 3. Mach サービスと launchd（なぜ「登録」が要るか）

ここが XPC で最もつまずきやすい部分です。

### Mach サービスと bootstrap（電話帳と交換台）

- AppA が SharedService に接続するには、SharedService の「電話番号」が必要です。XPC ではこの番号が **Mach サービス名**（例 `com.example.shared.service`）。
- 番号から相手を見つける仕組みが **bootstrap**、その管理役が **launchd**（macOS の常駐管理プロセス）です。番号を照会する処理を `bootstrap_look_up` と呼びます。
- **重要**: 電話帳に番号が登録されていなければ、照会は失敗します。アプリが `NSXPCListener(machServiceName: "...")` を作って `resume()` しても、その名前を launchd に登録していない限り、他プロセスからは見つけてもらえません。

### 登録の方法（LaunchAgent の plist）

番号を電話帳に載せる手続きが **LaunchAgent** です。`~/Library/LaunchAgents/` に置く設定ファイル（**plist** = Apple 形式の設定ファイル）で登録します。本プロジェクトの plist の要点:

```xml
<key>Label</key>          <!-- このジョブの名前 -->
<string>com.example.shared.service</string>
<key>ProgramArguments</key> <!-- launchd が起動する実行ファイルのパスと引数 -->
<array><string>.../SharedService.app/Contents/MacOS/SharedService</string></array>
<key>MachServices</key>    <!-- ここで電話帳に番号を登録する -->
<dict><key>com.example.shared.service</key><true/></dict>
<key>RunAtLoad</key>       <!-- false = 常時は起動せず、呼ばれたら起動する -->
<false/>
<key>StandardErrorPath</key> <!-- このプロセスのエラーログの出力先 -->
<string>/tmp/com.example.shared.service.err.log</string>
```

### オンデマンド起動

`RunAtLoad=false` と `MachServices` を組み合わせると、誰かがその番号に接続してきた瞬間に launchd がアプリを起動します（オンデマンド起動）。常時は動かさず、呼ばれたときだけ起動する形です。

注意点: launchd が起動するのは、plist の `ProgramArguments` に書かれたパスの実行ファイルです。そのパスが古い Debug ビルドを指していると、Release のつもりでも Debug が起動します（原因 #2）。

### bootstrap domain（電話帳は 1 冊ではない）

電話帳は状況ごとに分かれています（この分かれ方を domain と呼びます）。

- **`gui/<uid>`**: GUI ログインセッション用。通常のアプリはここ。`uid` はユーザー番号（`id -u` で確認、例 501）。
- **`user/<uid>`**: ユーザー単位。
- **`system`**: システム全体（root）。

同じ番号でも別の domain に載っていると見つかりません。たとえば `gui/501` に登録したサービスは、`system` から探しても見つかりません（原因 #3）。

### launchctl コマンド（電話帳の操作）

- `launchctl bootstrap gui/$(id -u) <plist>`: 登録する。
- `launchctl bootout gui/$(id -u) <plist>`: 登録を解除する。
- `launchctl print gui/$(id -u)/<サービス名>`: 登録状況を表示する（`state`, `program`, `MachServices` が見られる）。
- `launchctl kickstart -k gui/$(id -u)/<サービス名>`: 強制的に再起動する。

---

## 4. `.app` バンドルの中身

macOS のアプリ（`.app`）は、実体はフォルダです。要点だけ示します。

```
SharedService.app/
  Contents/
    MacOS/SharedService   ← 実際の実行ファイル（バイナリ）
    Info.plist            ← アプリの設定（識別子・種別など）
```

- **`Info.plist`** の `CFBundlePackageType = APPL` は「これはアプリです」という印。
- **`LSUIElement = YES`** は「Dock に表示しないアプリにする」設定。本プロジェクトのアプリは画面 UI を持たず常駐します。
- LaunchAgent の `ProgramArguments` は、この `SharedService.app/Contents/MacOS/SharedService` を直接指します。

---

## 5. コード署名

### なぜ署名するか

macOS は「このアプリを誰が作ったか」をデジタル署名で確認します。XPC でも、接続してきた相手が本物かを署名で検査できます（本プロジェクトでは検査していませんが、仕組みとして可能です）。

### 署名 identity（本人確認の証明書）の種類

| 種類 | 用途 | 特徴 |
|---|---|---|
| **ad-hoc（Sign to Run Locally）** | 手元で動かすだけ | チーム情報を持たない。`Signature=adhoc`。Debug で使用 |
| **Apple Development** | 開発・デバッグ用 | 有料登録で発行。本プロジェクトの Release で使用 |
| **Developer ID Application** | App Store 外への配布用 | 有料登録の管理者のみ発行可。Notarization に必須。本プロジェクトでは扱わない |

### 証明書の中身（`codesign -dv` で見える項目）

`codesign -dv --verbose=4 SharedService.app` の出力の読み方:

- **`Identifier=com.example.shared.service`**: アプリの Bundle ID（識別子）。
- **`TeamIdentifier=EXAMPLE123`**: **Team ID**。開発者アカウントごとの 10 桁の ID。証明書の中では **OU**（Organizational Unit）という欄に入っています。秘密の値ではなく公開情報です。
- **`Authority=...`**: 署名をたどれる証明の連なり。`Apple Development: ...` → `Apple Worldwide Developer Relations...` → `Apple Root CA` と、Apple の大元までさかのぼれます。誰が発行した署名かが分かります。
- **`flags=0x10000(runtime)`**: Hardened Runtime が有効な印（後述）。

---

## 6. Hardened Runtime / entitlements

- **Hardened Runtime**（`ENABLE_HARDENED_RUNTIME=YES`）: アプリに追加のセキュリティ制限をかける仕組み。Notarization の前提でもあります。本プロジェクトは Release だけ有効にしているため、Debug と Release の挙動差の一因になり得ます。
- **entitlements**: アプリに許可する特権の一覧（plist）。`get-task-allow`（デバッガ接続の許可。Debug にあり Release にない）、Library Validation（署名元が違うライブラリの読み込み禁止）などがあります。
- 注意: Mach サービスの番号照会自体は entitlement ではなく launchd への登録が前提です。Hardened Runtime が XPC 通信そのものを止めるわけではありません。

---

## 7. Notarization / quarantine / Gatekeeper / App Translocation

配布まわりの安全機構です（本プロジェクトでは Notarization は扱いませんが、用語として登場します）。

- **Notarization（公証）**: Apple にアプリを送り「マルウェアでない」と認証してもらう手続き。Developer ID 署名が必須です。
- **quarantine（検疫）**: ネットからダウンロードしたファイルに付く印（拡張属性 `com.apple.quarantine`）。`xattr` コマンドで確認・削除できます。
- **Gatekeeper**: quarantine の付いたアプリを起動してよいか判定する macOS の保護機能。`spctl --assess` で評価を確認できます。
- **App Translocation**: quarantine 付きのアプリを移動せずに起動すると、macOS が実行ファイルを `/private/var/folders/.../AppTranslocation/...` という読み取り専用の一時パスにコピーして動かす仕組み。これが起きると、LaunchAgent が固定パスを前提にしているため起動対象を見失います（原因 #6）。

---

## 8. Debug ビルドと Release ビルドの違い

同じソースコードでも、ビルド設定が違います。本プロジェクトでの差:

| 項目 | Debug | Release |
|---|---|---|
| 署名 | ad-hoc（Sign to Run Locally） | Apple Development（Team `EXAMPLE123`） |
| Hardened Runtime | 無効 | 有効 |
| Bundle ID | `com.example.shared.service.Debug`（末尾に `.Debug`） | `com.example.shared.service` |

「Debug は通って Release だけ失敗する」のは、コードのロジックではなく、この表の差や環境の違いが原因、というのが本プロジェクトの主張です。

---

## 9. このプロジェクトの全体像

- **`SharedService.app` だけが listener（提供役 = vendor）**、AppA / AppB はクライアントです。NSConnection の対等なやり取りをそのまま移すのではなく、Apple が想定する形にして安定させています。
- **vendor / client**: サービスを提供する側（listener を持つ側）が vendor、利用する側（接続する側）が client です。
- **push / GreetingCard**: AppA と AppB は SharedService を経由してメッセージ（`GreetingCard`）を送り合います。SharedService は `send` された瞬間に宛先クライアントへ push しますが、メッセージをためる仕組み（mailbox）はないため、相手が接続中でないと届かず消えます。
- 移行の推奨: 対等な形をやめて listener を 1 つに絞り（本デモの SharedService）、双方向が必要なら提供役を 1 つ挟みます。

---

## 10. 「Debug 成功・Release 失敗」の主な原因

README の原因リストを、たとえで言い換えたものです。このプロジェクトのアプリはコード側で接続を拒否しないため、原因はすべて**環境の違い**から起きます。

1. **番号が電話帳に未登録** — そもそも相手が見つからない（launchd への登録漏れ）。
2. **電話帳の番号が古いパスを指す** — launchd が古い Debug の `.app` を起動する（パス不一致）。最も多い原因。
3. **別の電話帳を見ている** — `gui/501` に登録したのに別の domain から探している。
4. **Release だけの追加制限** — Hardened Runtime / entitlements の差。
5. **検疫でアプリが別の場所にコピーされた** — App Translocation でパスがずれる。
6. **エラーをログに出していない** — 同期呼び出しの errorHandler を出していないと失敗理由が見えない。

同じコードのまま環境の違いだけで失敗するので、切り分けはまず launchd への登録・パス・domain の 3 点から始めるのが近道です。

---

## 11. 用語集（README / DIAGNOSIS 早見表）

読みながら分からない語が出たときの索引です。詳しい説明は本文の各節にあります。

| 用語 | 一言で |
|---|---|
| IPC | プロセス間通信。別アプリどうしのやり取り |
| NSConnection | 旧 IPC（非推奨）。XPC の前身 |
| XPC / NSXPCConnection | 現行 IPC。相手のオブジェクトを呼べる |
| NSXPCListener | 接続を待ち受ける側（サーバー役） |
| Mach サービス名 / machServiceName | 相手を見つけるための「電話番号」 |
| proxy | 相手オブジェクトの代理。呼ぶと相手側で動く |
| remoteObjectInterface | 相手を呼ぶための取り決め |
| exportedInterface / exportedObject | 自分が提供する機能とその実体 |
| shouldAcceptNewConnection | 接続を受けるか判断する場所 |
| interruption / invalidation Handler | 接続が中断/無効化されたときの通知 |
| 同期 proxy / errorHandler | 返事を待つ呼び出しと、その失敗理由 |
| GreetingCard | 本プロジェクトの自作クラス（`NSSecureCoding`）。AppA/AppB 間で送るオブジェクト |
| push | 相手が接続中なら SharedService が即座に `receive` を呼び返す仕組み。mailbox がないので未接続なら delivered=false で消える |
| Mach service | XPC の通信窓口（番号で識別） |
| bootstrap / bootstrap_look_up | 番号から相手を探す仕組みと、その照会 |
| launchd | macOS の常駐管理プロセス（電話帳の管理役） |
| LaunchAgent / plist | サービスを登録する設定ファイル |
| ProgramArguments | launchd が起動する実行ファイルのパスと引数 |
| MachServices | plist 内で番号を電話帳に登録するキー |
| RunAtLoad | 常時起動するか。false = オンデマンド |
| bootstrap domain（gui/user/system） | 状況別の電話帳。gui/<uid> が GUI 用 |
| launchctl | 電話帳を操作するコマンド |
| .app バンドル | アプリの実体（フォルダ）。中に Contents/MacOS/<exec> |
| Info.plist / CFBundlePackageType | アプリ設定。APPL = アプリの印 |
| LSUIElement | Dock に表示しないアプリにする設定 |
| コード署名 / codesign | 誰が作ったかの証明と、その確認コマンド |
| ad-hoc / Sign to Run Locally | チーム情報を持たないローカル署名 |
| Apple Development | 開発用署名 |
| Developer ID Application | 配布用署名（Notarization 必須） |
| Team ID / OU | 開発者アカウントの 10 桁 ID（証明書の OU 欄） |
| Hardened Runtime / flags=runtime | 追加のセキュリティ制限（Release で有効） |
| entitlements / get-task-allow | 特権の一覧 / デバッガ許可（Debug のみ） |
| Notarization | Apple の公証。Developer ID が必須 |
| quarantine | ダウンロード由来の検疫印 |
| Gatekeeper / spctl | 起動可否を判定する保護機能 / 評価コマンド |
| App Translocation | 検疫アプリを一時パスへコピーして動かす仕組み |

---

## 12. 診断コマンドの出力の読み方

DIAGNOSIS のコマンドは、実行して終わりではなく出力を読むことが目的です。

### `launchctl print gui/$(id -u)/com.example.shared.service`

- `state = running / not running`: いま起動しているか。
- `program = .../build/Debug/...` or `.../build/Release/...`: どのビルドを指しているか。Release を検証中なのに Debug を指していたら原因 #2 です。
- `Could not find service ...`: 電話帳に未登録（原因 #1、または domain 違いの #3）。

### `codesign -dv --verbose=4 SharedService.app`

- `Identifier=` の末尾が `.Debug` か無しか → どのビルドか。
- `TeamIdentifier=EXAMPLE123` → Team ID。
- `flags=0x10000(runtime)` → Hardened Runtime 有効（Release のはず）。
- `Authority=Apple Development:...` → どの種類の署名か。

### ログ（失敗の理由はここ）

- クライアント側 stderr の `同期 proxy error: Couldn't communicate with a helper application.` → 「通信に失敗した」事実だけで、理由はここには出ません。
- クライアント側 stderr の `送信結果 to=... delivered=false` → 接続自体は成功しているが、push した瞬間に相手が接続していなかったという意味です。mailbox がないため、この場合メッセージは失われます。
- listener 側ログ（`/tmp/com.example.shared.service.err.log`）に `shouldAcceptNewConnection` や `interruption` / `invalidation` が出ているか → 接続がどこまで進んだかの手がかりです。
- `log stream --style compact --predicate '...'` → システム全体のログをリアルタイム表示。`com.example` や `AppTranslocation` で絞り込みます。

> **診断のコツ**: クライアント側の「失敗した」だけを見て悩まないこと。listener 側のログと `launchctl print` の `program` パスを必ず突き合わせます。Release 失敗の理由は、たいていこの 2 か所に出ます。

---

## 13. 次の一歩

このガイドで README / DIAGNOSIS が読めるようになったら、次の順で手を動かしてみてください。詳しいコマンドは [DIAGNOSIS.md](DIAGNOSIS.md) にあります。

1. DIAGNOSIS の「7. 同期呼び出しのエラーと push の到達」を Debug で実行し、成功時のログに慣れる。
2. DIAGNOSIS の「LaunchAgent が Debug を指したままになる問題の再現」を実行し、Debug の LaunchAgent を登録したまま Release をテストして失敗を再現する。
3. `install_launchagents.sh Release` で plist を登録し直し、解消することを確認する。
4. 自分のアプリに当てはめる。LaunchAgent のパスは正しいか、Mach サービスは登録されているか、Debug と Release で何が違うかを、上の読み方で確認する。
