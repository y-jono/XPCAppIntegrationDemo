# 入門ガイド — README / DIAGNOSIS を読むための前提知識

このドキュメントは、`README.md` と `DIAGNOSIS.md` に出てくる用語を**ゼロから**理解するための補助教材です。XPC・launchd・コード署名の知識がなくても、上から順に読めば両ドキュメントが読めるようになることを目指します。

> 読む順番の目安: まず本書の「1〜4」を読むと README の前半が、「5〜8」を読むと署名まわりが、「9〜11」を読むと原因リストと診断コマンドが理解できます。急ぐ場合は **11 の用語集**と**12 の診断コマンドの読み方**だけ先に見ても構いません。

---

## 0. この問題を一言で

> **2つのアプリ（AppA / AppB）が会話する。Debug ビルドでは会話できるのに、Release ビルドでは会話できない。なぜか。**

「会話」の仕組みが **XPC**、会話相手を見つける「電話帳」が **launchd / Mach service**、相手が本物かを確かめる「身分証」が **コード署名**です。Debug と Release ではこの3つの条件が微妙に変わるため、Release だけ会話に失敗することがあります。

---

## 1. 大前提: プロセスとプロセス間通信 (IPC)

- **プロセス** = 実行中のアプリ1個。AppA と AppB は**別プロセス**＝別々のメモリ空間で動く、別人です。
- 別人どうしなので、関数を直接呼び合えません。間に「通信」が必要です。これが **IPC (Inter-Process Communication)**。
- 昔の macOS は **NSConnection** という IPC を使っていましたが、非推奨 (deprecated) になりました。後継が **XPC**（`NSXPCConnection`）です。
- このプロジェクトは「NSConnection → XPC へ載せ替えたら Release で動かない」という移行トラブルの再現です。

---

## 2. XPC の基本モデル

XPC は「相手プロセスのオブジェクトを、あたかも手元のオブジェクトのように呼ぶ」仕組みです。登場人物は3つ:

| 用語 | 役割 | 例え |
|---|---|---|
| **`NSXPCListener`** | 接続を**待ち受ける**側（サーバー役） | 電話を受ける人 |
| **`NSXPCConnection`** | 接続を**かける**側（クライアント役） | 電話をかける人 |
| **proxy（プロキシ）** | 相手オブジェクトの「影武者」。これを呼ぶと相手側で実行される | 受話器 |

### インターフェース（何を呼べるかの取り決め）
電話で話す「話題のリスト」を事前に決めます。それが **protocol**（`@objc` を付けて Objective-C 互換にする）。接続には2つの向きがあります:

- **`remoteObjectInterface`**: 「**相手に**呼んでもらう／相手を呼ぶ」ためのインターフェース（=相手が提供する機能）。
- **`exportedInterface` + `exportedObject`**: 「**自分が**提供する」機能と、その実体オブジェクト。

> 例: AppA が `proxy.ping("hello")` と呼ぶ → 相手プロセスの `ping` が実行され、`reply("pong")` が返ってくる。

### 双方向のやり方（1接続 vs 2接続）
- **1接続双方向**: 1本の接続に `remoteObjectInterface`（相手を呼ぶ）と `exportedInterface`（自分も呼ばれる）を**両方**載せる。電話1本で双方向に話す形。**片側だけが listener** で済み、これが XPC の素直な形。
- **2接続**: AppA も AppB も**それぞれ listener を持ち**、互いに電話をかけ合う。電話回線が2本。待ち受けが2つある分、後述の「登録・署名・ドメイン」の失敗ポイントも**2倍**になる。

### 接続の状態を知るハンドラ（ログの要）
- **`shouldAcceptNewConnection`**: listener 側で「この接続を受けるか？」を判断する関門。ここで相手の身分（署名）を検査し、ダメなら `false`（＝拒否）。
- **`interruptionHandler`**: 相手プロセスが落ちた等で**一時中断**したとき呼ばれる。
- **`invalidationHandler`**: 接続が**完全に無効化**されたとき呼ばれる。
- **`synchronousRemoteObjectProxyWithErrorHandler`**: **同期**（返事が来るまで待つ）でプロキシを取る。`errorHandler` に失敗理由が渡る。**ここをログに出さないと真因が消える**ので、診断では最重要。

---

## 3. 名前付き Mach サービスと launchd（なぜ「登録」が要るか）

ここが XPC 最大のつまずきポイントです。

### Mach service と bootstrap = 電話交換台
- AppA が AppB に電話したいとき、AppB の「番号」を知る必要があります。XPC ではこの番号が **Mach service 名**（例 `com.example.appB.service`）。
- 番号から相手を見つける「電話交換台」が **bootstrap** という仕組みで、その管理人が **launchd**（macOS の常駐管理プロセス）。
- **重要**: 電話帳に番号が**登録されていないと**、`bootstrap_look_up`（番号照会）は失敗します。アプリが `NSXPCListener(machServiceName: "...")` を作って `resume()` しても、**その名前を launchd に登録していなければ、他プロセスから見つけてもらえません**。

### 登録の方法 = LaunchAgent の plist
名前を電話帳に載せる手続きが **LaunchAgent**。`~/Library/LaunchAgents/` に置く設定ファイル（**plist** = Apple 形式の設定ファイル）です。本プロジェクトの plist の中身:

```xml
<key>Label</key>          <!-- このジョブの名前 -->
<string>com.example.appB.service</string>
<key>ProgramArguments</key> <!-- launchd が起動する実行ファイルのパス＋引数 -->
<array><string>.../AppB.app/Contents/MacOS/AppB</string><string>--listen-only</string></array>
<key>MachServices</key>    <!-- ★ここで電話帳に番号を登録 -->
<dict><key>com.example.appB.service</key><true/></dict>
<key>RunAtLoad</key>       <!-- false = 普段は起動せず、呼ばれたら起動（オンデマンド） -->
<false/>
<key>StandardErrorPath</key> <!-- このプロセスのエラーログの出力先 -->
<string>/tmp/com.example.appB.service.err.log</string>
```

### オンデマンド起動
`RunAtLoad=false` + `MachServices` の組み合わせで、**誰かがその番号に電話してきた瞬間に launchd がアプリを起動**します。普段は寝ていて、呼ばれたら起きる。これが「on-demand 起動」。
→ ここに落とし穴: launchd が起動するのは plist の `ProgramArguments` のパスにある実行ファイルです。**そのパスが古い Debug ビルドを指していると、Release のつもりでも Debug が起動します**（原因 #2）。

### bootstrap domain（電話帳は1冊ではない）
電話帳は文脈ごとに分かれています:
- **`gui/<uid>`**: GUI ログインセッション用（普通のアプリはここ）。`uid` はユーザー番号（`id -u` で確認、例 501）。
- **`user/<uid>`**: ユーザー単位。
- **`system`**: システム全体（root）。
同じ番号でも**別の電話帳に載っていると見つかりません**（原因 #3）。

### launchctl コマンド（電話帳の操作）
- `launchctl bootstrap gui/$(id -u) <plist>`: 電話帳に登録（ロード）。
- `launchctl bootout gui/$(id -u) <plist>`: 登録解除（アンロード）。
- `launchctl print gui/$(id -u)/<service名>`: 登録状況を表示（`state`, `program`, `MachServices` が見られる）。
- `launchctl kickstart -k gui/$(id -u)/<service名>`: 強制的に再起動。

---

## 4. `.app` バンドルの中身

macOS のアプリ（`.app`）は実は**フォルダ**です。中身の要点:

```
AppB.app/
  Contents/
    MacOS/AppB        ← 実際の実行ファイル（バイナリ）
    Info.plist        ← アプリの設定（識別子・種別など）
```

- **`Info.plist`** の `CFBundlePackageType = APPL` は「これはアプリです」の印。
- **`LSUIElement = YES`** は「Dock に出さない常駐型（エージェント）」の印。本プロジェクトのアプリは UI を持たない常駐型。
- LaunchAgent の `ProgramArguments` は、この `AppB.app/Contents/MacOS/AppB` を直接指します。

---

## 5. コード署名（ゼロから）

### なぜ署名するか
macOS は「このアプリは誰が作った本物か」を**デジタル署名**で確認します。XPC でも、接続相手が本物かを署名で検査できます。

### 署名 identity（身分証）の種類
| 種類 | 用途 | 特徴 |
|---|---|---|
| **ad-hoc（Sign to Run Locally）** | ローカルで動かすだけ | チーム情報なし。`Signature=adhoc`。Debug で使用 |
| **Apple Development** | 開発・デバッグ用 | 有料登録で発行。今回 Release でこれを使用 |
| **Developer ID Application** | App Store 外への**配布**用 | 有料＋Account Holder のみ。**Notarization に必須**。今回はメンバーシップ期限切れで作れない |

### 証明書の構造（`codesign -dv` で見える項目）
`codesign -dv --verbose=4 AppA.app` の出力の読み方:
- **`Identifier=com.example.AppA`**: アプリの Bundle ID（識別子）。
- **`TeamIdentifier=EXAMPLE123`**: **Team ID**。開発者アカウントごとの10桁 ID。証明書の中では **OU**（Organizational Unit）という欄に入っている。**公開情報**（秘密ではない）。
- **`Authority=...`**: 署名の「証明の連鎖」。`Apple Development: ...` → `Apple Worldwide Developer Relations...` → `Apple Root CA` と、Apple のルートまで遡れる。
- **`flags=0x10000(runtime)`**: **Hardened Runtime が有効**な印（後述）。

### requirement（要件）言語 — 「どんな相手なら信用するか」のルール
接続相手の署名が満たすべき条件を文字列で書きます。本プロジェクトに出てくる例:

| requirement 文字列 | 意味 |
|---|---|
| `anchor apple generic` | Apple のルートまで遡れる正規署名であること（Apple 発行ならOK） |
| `certificate leaf[subject.OU] = "EXAMPLE123"` | 末端証明書の OU（＝Team ID）が `EXAMPLE123` であること |
| `certificate leaf[field.1.2.840.113635.100.6.1.13] exists` | **Developer ID Application 専用のマーカー**（OID 1.2.840.113635.100.6.1.13）を持つこと |

> **今回の「壊れた要件」の正体**: Release は `...6.1.13 exists`（Developer ID 専用マーカー）を要求しているのに、実際の署名は **Apple Development**（このマーカーを持たない）。だから条件不成立で拒否。`BUILD_USE_CORRECT_REQUIREMENT=1` にすると要件が `OU="EXAMPLE123"`（Team ID 一致）に変わり、Apple Development でも通る。

### 検証 API とエラー番号
- `SecCodeCheckValidity(code, [], requirement)` で「この相手は要件を満たすか」を判定。
- 戻り値 **`0`** = 合格、**`-67050`**（`errSecCSReqFailed`）= **要件不一致で不合格**。
- DIAGNOSIS のログ `status=-67050` を見たら「署名は正しいが、要件の条件に合わなかった」と読む。

---

## 6. Hardened Runtime / entitlements

- **Hardened Runtime**（`ENABLE_HARDENED_RUNTIME=YES`）: アプリに追加のセキュリティ制限をかける仕組み。Notarization の前提でもある。Release だけ有効にしているため、Debug/Release の挙動差の一因になりうる。
- **entitlements**: アプリに許可する特権の一覧（plist）。`get-task-allow`（デバッガ接続許可。Debug にあり Release になし）、Library Validation（署名元が違うライブラリのロード禁止）など。
- 注意: **XPC の「番号照会」自体は entitlement ではなく launchd 登録が前提**。Hardened Runtime が XPC 通信そのものを直接止めるわけではない。

---

## 7. Notarization / quarantine / Gatekeeper / App Translocation

配布まわりの安全機構です（今回は Notarization は対象外だが、用語として登場する）:

- **Notarization（公証）**: Apple にアプリを送って「マルウェアでない」と認証してもらう手続き。**Developer ID 署名が必須**。
- **quarantine（検疫）**: ネットからダウンロードしたファイルに付く印（拡張属性 `com.apple.quarantine`）。`xattr` コマンドで確認・削除。
- **Gatekeeper**: quarantine の付いたアプリの起動可否を判定する番人。`spctl --assess` で評価を確認。
- **App Translocation**: quarantine 付きアプリを**移動せずに**起動すると、macOS が実行ファイルを `/private/var/folders/.../AppTranslocation/...` という**ランダムな読み取り専用パスへ一時コピー**して動かす仕組み。
  → これが起きると、LaunchAgent が固定パスを前提にしていると**パスがずれて壊れます**（原因 #6）。

---

## 8. Debug ビルド と Release ビルドは何が違うのか

「同じソースコード」でも、ビルド設定が違います。本プロジェクトでの差:

| 項目 | Debug | Release |
|---|---|---|
| 署名 | ad-hoc (Sign to Run Locally) | Apple Development (Team `EXAMPLE123`) |
| Hardened Runtime | 無効 | **有効** |
| Bundle ID | `com.example.AppA.Debug`（suffix あり） | `com.example.AppA`（suffix なし） |
| 署名要件チェック | **`#if DEBUG` でスキップ** | **有効**（壊れた要件で拒否） |

→ **「Debug は通って Release だけ落ちる」のは、コードのロジックではなく、この表の差のどれかが原因**、というのが本プロジェクトの主張です。

---

## 9. このプロジェクトの全体像

- **構成A (`ConfigurationA/`)**: AppA も AppB も**両方 listener**（対称）。NSConnection の対称 P2P をそのまま移した形＝**アンチパターン寄り**。失敗ポイントが多い。
- **構成B (`ConfigurationB/`)**: **`SharedService` だけが listener**（vendor）、AppA/AppB は client。**Apple 推奨の形**で安定しやすい。
- **vendor**: サービスを提供する側（listener を持つ）。**client**: 利用する側（接続する）。
- 移行の推奨: 対称 P2P をやめ、**単一 vendor**（SharedService か LaunchAgent）に寄せ、双方向が必要なら 1接続双方向にする。

---

## 10. 「Debug成功・Release失敗」8原因を素人語で

README の優先原因リストの言い換え:

1. **番号が電話帳に未登録** → そもそも相手が見つからない（launchd 登録漏れ）。
2. **電話帳の番号が古い住所を指す** → launchd が古い Debug の `.app` を起動（パス不一致）。**最頻出**。
3. **別の電話帳を見ている** → `gui/501` に登録したのに別ドメインから探している。
4. **相手の身分証チェックが厳しすぎ/間違い** → 要件不一致で拒否（今回の決定的再現はこれ）。
5. **Release だけの追加制限** → Hardened Runtime / entitlements の差。
6. **検疫でアプリが別の場所にコピーされた** → translocation でパスがずれる。
7. **Bundle ID の suffix 食い違い** → Debug 用 ID を前提にした要件が Release を弾く。
8. **エラーを握り潰している** → 同期呼び出しの errorHandler をログ化していないと真因が見えない。

> 補足（重要）: #1〜#3・#6 は**同じコードのまま環境差だけで壊れる「環境型」**。#4・#7 は**署名チェックのコードがあって初めて起きる「コード起因型」**。あなたの実機がどちらかは、listener に署名チェックがあるかを実物で見るのが切り分けの第一歩。

---

## 11. 用語集（README / DIAGNOSIS 早見表）

| 用語 | 一言で |
|---|---|
| IPC | プロセス間通信。別アプリどうしの会話 |
| NSConnection | 旧 IPC（非推奨）。XPC の前身 |
| XPC / NSXPCConnection | 現行 IPC。相手のオブジェクトを呼べる |
| NSXPCListener | 接続を待ち受ける側（サーバー役） |
| machServiceName | 相手を見つけるための「電話番号」 |
| proxy | 相手オブジェクトの影武者。呼ぶと相手で実行 |
| remoteObjectInterface | 相手を呼ぶための取り決め |
| exportedInterface / exportedObject | 自分が提供する機能とその実体 |
| shouldAcceptNewConnection | 接続を受けるか判断する関門（署名検査の場所） |
| interruption / invalidation Handler | 接続が中断/無効化されたときの通知 |
| 同期 proxy / errorHandler | 返事を待つ呼び出しと、その失敗理由 |
| Mach service | XPC の通信窓口（番号で識別） |
| bootstrap / bootstrap_look_up | 番号から相手を探す交換台と照会 |
| launchd | macOS の常駐管理プロセス（電話帳の管理人） |
| LaunchAgent / plist | サービスを登録する設定ファイル |
| ProgramArguments | launchd が起動する実行ファイルのパス＋引数 |
| MachServices | plist 内で番号を電話帳に載せるキー |
| RunAtLoad | 常時起動するか。false=オンデマンド |
| bootstrap domain (gui/user/system) | 文脈別の電話帳。gui/<uid> が GUI 用 |
| launchctl | 電話帳を操作するコマンド |
| .app バンドル | アプリ実体（フォルダ）。中に Contents/MacOS/<exec> |
| Info.plist / CFBundlePackageType | アプリ設定。APPL=アプリの印 |
| LSUIElement | Dock に出ない常駐型の印 |
| コード署名 / codesign | 「誰が作った本物か」の証明 |
| ad-hoc / Sign to Run Locally | チーム無しのローカル署名 |
| Apple Development | 開発用署名 |
| Developer ID Application | 配布用署名（Notarization 必須） |
| Team ID / OU | 開発者アカウントの10桁ID（証明書のOU欄） |
| anchor apple generic | Apple 正規署名であること |
| certificate leaf | 末端（実際に使う）証明書 |
| requirement | 信用する相手の条件を書いた式 |
| SecCodeCheckValidity | 署名/要件を検証する API |
| errSecCSReqFailed (-67050) | 要件不一致で不合格 |
| Hardened Runtime / flags=runtime | 追加セキュリティ制限（Release で有効） |
| entitlements / get-task-allow | 特権一覧 / デバッガ許可（Debugのみ） |
| Notarization | Apple の公証。Developer ID 必須 |
| quarantine | ダウンロード由来の検疫印 |
| Gatekeeper / spctl | 起動可否の番人 / 評価コマンド |
| App Translocation | 検疫アプリをランダムパスへ一時コピーする機構 |

---

## 12. 診断コマンドの「出力の読み方」

DIAGNOSIS のコマンドは「実行して終わり」ではなく**出力を読む**のが本番です。

### `launchctl print gui/$(id -u)/com.example.appB.service`
- `state = running / not running`: 今起動しているか。
- `program = .../build/Debug/...` or `.../build/Release/...`: **どのビルドを指しているか**（原因 #2 の核心。Release を検証中なのに Debug を指していたら NG）。
- `Could not find service ...`: **電話帳に未登録**（原因 #1 / ドメイン違い #3）。

### `codesign -dv --verbose=4 AppA.app`
- `Identifier=` が `.Debug` 付きか無しか → どのビルドか。
- `TeamIdentifier=EXAMPLE123` → Team ID。
- `flags=0x10000(runtime)` → Hardened Runtime 有効（Release のはず）。
- `Authority=Apple Development:...` → どの種類の署名か。

### ログ（最重要の真因はここ）
- クライアント側 stderr に `同期 proxy error: Couldn't communicate with a helper application.` → 「会話に失敗した」事実だけ。**理由はここには出ない**。
- listener 側ログ（`/tmp/com.example.*.err.log`）に `署名検査: requirement='...' status=-67050` → **真の理由（要件不一致）**。
- `log stream --style compact --predicate '...'`: システム全体のログをリアルタイム表示。`com.example` や `AppTranslocation` で絞り込む。

> **診断の鉄則**: クライアントの「失敗した」だけ見て悩まない。**listener 側のログ**と **`launchctl print` の `program` パス**を必ず突き合わせる。Release 失敗の真因はたいていこの2か所に出ます。

---

## 13. 次の一歩

このガイドで README / DIAGNOSIS が読めるようになったら、実際に手を動かす順番:

1. `DIAGNOSIS.md` の「8. 同期 XPC 呼び出しの errorHandler」を Debug で実行し、**成功時のログ**を見て慣れる。
2. 「5. code signing requirement 拒否」を Release で実行し、**失敗時のログ**（`-67050`）を見る。
3. `BUILD_USE_CORRECT_REQUIREMENT=1` で**直る**ことを確認する。
4. 自分の実アプリに当てはめる: listener に署名チェックがあるか / LaunchAgent のパスは正しいか / Debug と Release で何が違うか、を上の読み方で確認する。
