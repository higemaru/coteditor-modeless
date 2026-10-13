# CotEditor でモードレス変換

ローマ字のまま打って **Ctrl+J** を押すと、直前のローマ字を日本語に変換する。
Emacs の boiled-egg / yc.el / mozc-temp のような「モードを切り替えずに日本語入力」を、
CotEditor と macOS 標準の日本語入力で実現する。

```
asitahakittoiihininaru|   ← Ctrl+J
        ↓
明日はきっといい日になる|  ← 候補選択・Enter（または Ctrl+M）で確定、確定後に IME は自動で OFF
```

## 仕組み

```
CotEditor ── Ctrl+J → modeless-convert.applescript
                          ・カーソル直前のローマ字を選択
                          ・FIFO（プロセス間の受け渡し口）にテキストを 1 行書く
                                     ↓
                        modeless-type（Swift・常駐）
                          1. Delete（選択範囲を削除）
                          2. かな（IME ON）
                          3. ローマ字を物理キーで再入力
                          4. Space（変換開始）
                          5. Enter / テンキー Enter / Ctrl+M を検知 → 英数（IME OFF）
```

役割分担は「エディタ固有の処理（AppleScript）」と「IME・キー送信（Swift）」。
Swift 側は「いま選択されている範囲を処理する」だけで、どのエディタかは関知しない。

## ファイル

| ファイル | インストール先 | 役割 |
|---|---|---|
| `install.sh` | — | ビルド・配置・常駐の登録。アンインストールも |
| `src/modeless-convert.applescript` | `~/Library/Application Scripts/com.coteditor.CotEditor/` | 範囲の取得・選択、Swift への受け渡し |
| `src/modeless-type.swift` | ビルドして `~/bin/modeless-type` | 常駐。キー送信と確定検知 |
| `src/modeless-type.plist` | `~/Library/LaunchAgents/local.modeless-type.plist` | ログイン時に Swift を常駐させる。バイナリのパスは `install.sh` が書き込む |

## 導入（初回）

### 1. install.sh を実行
```
./install.sh
```

次のことを順に行う。

1. Xcode コマンドラインツールが無ければインストール（ダイアログに従う。完了まで待つ）
2. ビルドして `~/bin/modeless-type` に設置
3. .plist を設置し、プログラム設置場所を`~/bin/modeless-type` に書き換え
4. AppleScript を CotEditor のスクリプトフォルダに設置
5. 許可設定（後述）
6. 常駐を開始

`~/bin` 以外に置く場合は `BIN_DIR=/path/to/dir ./install.sh`。

### 2. 許可設定

install.sh の途中で、システム設定の画面が 1 つずつ開くので、許可設定を行う。
それぞれに `~/bin/modeless-type` を追加して（`+` ボタン → Cmd+Shift+G でパスを入力）、Terminal に戻って Enter を押す。

- アクセシビリティ（キー送信に必要）
- 入力監視（Enter の検知に必要）

### 3. ショートカットを割り当てる
システム設定 → キーボード → キーボードショートカット → アプリのショートカット で、
アプリケーションに CotEditor、メニュータイトルに `modeless-convert` を指定し、Ctrl+J などを割り当てる。

CotEditor は、スクリプトのファイル名から拡張子を除いたものをメニューに表示する。
ファイル名を変えた場合は、メニュータイトルも合わせる。

### 4. 動作確認
ローマ字を打つ → Ctrl+J → 変換が始まる → Enter（または Ctrl+M）で確定 → IME が OFF になる。

## 更新・保守

### 更新する
ソースを変えた時や、新しい版を取得した時は、もう一度実行する。

```
./install.sh
```

再ビルドすると署名が変わり、許可が無効になる。
アクセシビリティと入力監視の両方で `modeless-type` を `-` で削除し、`+` で入れ直す
（スイッチのオフオンでは直らない）。

### 一時的に止める・再起動する
```
launchctl bootout gui/$(id -u)/local.modeless-type        # 止める
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.modeless-type.plist   # 再開する
launchctl kickstart -k gui/$(id -u)/local.modeless-type   # 再起動する（許可を付け直した後など）
```

### 削除

```
./install.sh uninstall
```
そのあと、システム設定画面で、アクセシビリティと入力監視の一覧から `modeless-type` を `-` で削除する。

## うまく動かない時

| 症状 | 原因の目安 |
|---|---|
| Ctrl+J でビープが鳴る | 常駐が止まっている。`launchctl list \| grep modeless` で確認。または、選択範囲にスペースや日本語が含まれている。または、いまのキーボードレイアウトで打てない文字が含まれている（ログに `no key for` が出る）。または、前の変換を処理している最中 |
| 範囲が選択されるだけで何も起きない | アクセシビリティの許可が無効（再ビルド後に多い） |
| 変換はできるが、確定後に IME が OFF にならない | 入力監視の許可が無効。`~/Library/Logs/modeless-type.log` に `tapCreate failed` が出る |
| 頭の数文字が取りこぼされる | `imeOnWait` を 100ms → 150ms にして、`./install.sh` で入れ直す |
| 常駐しない（`launchctl list \| grep modeless` に出ない）。`launchctl bootstrap` が `Input/output error` で失敗する | plist に quarantine 属性（ダウンロード由来）が付いている。`xattr -c ~/Library/LaunchAgents/local.modeless-type.plist` で外してから `bootstrap` し直す。現在の `install.sh` は自動で外す |
| Ctrl+J で何も起きない（ビープもなし） | 直前が変換対象の文字でない（日本語・スペース・改行の直後や行頭）。仕様 |

調査したい時は、Swift 冒頭の `debugLog` を `true` にして、`./install.sh` で再インストール
（ログは `~/Library/Logs/modeless-type.log`。失敗系のログは `debugLog` に関係なく常に出力）。

## 設定

### Swift（`src/modeless-type.swift` 冒頭）

- `imeOnKey` / `imeOffKey`: IME ON/OFF のキーコード（既定: かな=104、英数=102）
- `confirmKeyCodes` / `confirmWithCtrlKeyCodes`: 確定として扱うキー（既定: Return、テンキー Enter、Ctrl+M）
- `afterDeleteWait` / `imeOnWait` / `keyGap` / `beforeSpaceWait` / `afterConfirmWait`: 待ち時間。取りこぼすなら増やす
- `watchTimeoutSec`: 確定待ちの上限（既定 30 秒）

### AppleScript（`src/modeless-convert.applescript` 冒頭）
- `maxScan`: 直前を何文字まで遡るか（既定 100）

変更したら `./install.sh` で入れ直す。

## 挙動の詳細

- 遡る範囲: カーソル直前の ASCII 文字（`!` から `~` まで。スペースは含まない）が連続する部分。行頭・スペース・タブ・日本語に当たったら止まる。直前が対象の文字でなければ何もしない
- 選択範囲がある場合: 選択が対象の文字だけの時に限って動く。日本語やスペースを含む選択は、ビープを鳴らして何もしない
- 記号も含めて、すべてキー入力として IME に渡す。記号がどう入力されるか（`~` が「〜」になるなど）は IME の設定しだい
- Ctrl を押したまま: 送信する各キーのフラグを空にしているので、Ctrl+K や Ctrl+O にならない
- 確定待ちは 30 秒で解除。Enter・Ctrl+M 以外で確定した場合、IME は OFF にならない（手動で英数キーを押す）
- Esc で変換を取り消しても、確定待ちは続く。30 秒以内に Enter を押すと、その時点で英数が送られる
- 変換の処理中（キーの送信中や、確定後に英数を送るまでの間）に届いた要求は、受け付けずにビープを鳴らす
- キーの送信中に別のアプリへ切り替えた場合は、送信を中断する（別のアプリに打ち込まない）
- 確定待ちの間に別のアプリで Enter を押しても、英数は送らない。元のアプリに戻って確定した時に送る。同じアプリの別の窓で Enter を押した場合は、窓を区別しないので英数が送られる

## 他の IME・キー設定

- このツールが送るのは、仮想キーコード（かな/英数）、文字のキー（必要なら Shift 付き）、Delete、Space。物理キーのリマップ（Karabiner など）の影響は受けない
- IME 側で かな/英数 の意味を変えている場合や、トグル式にしている場合は、`imeOnKey` / `imeOffKey` の調整が要る
- macOS 26 Tahoe、macOS 27 Golden Gate で動作を確認
- macOS 標準の日本語入力、azooKey、Google 日本語入力で動作を確認
- 他の IME は未検証
- キー配列は US 配列でのみ確認。ほかの配列（JIS など）は未検証

## 設計メモ

- **常駐にした理由**: CotEditor 経由でバイナリを起動すると、プロセスの初期化に約 0.5 秒かかった（Terminal からだと 36ms）。署名し直し・属性の削除では改善せず、常駐化で解消した
- **優先度の指定**: plist の `ProcessType: Interactive` とワーカーの `userInteractive` を外すと、キー送信が約 2 倍遅くなった。付けたまま使う
- **選択範囲の削除は Swift 側で行う**: AppleScript は対象のローマ字を選択するだけで、削除は Swift が Delete キーを送って行う。こうしておくと AppleScript の仕事は「選択する」だけになり、ほかのエディタに対応する時も、選択の部分を書けばすむ
- **文字をキー入力で送る理由**: IME が受け付けるのはキー入力だけで、文字列のイベント（`keyboardSetUnicodeString`）として送った文字は IME に届かずに消える。そのため、すべての文字をキーコードと Shift の組み合わせで送る。対応表は要求のたびに、いまの ASCII 用キーボードレイアウトに `UCKeyTranslate` で問い合わせて作る。US / JIS で記号の位置が違っても、これで合わせられる。テンキーとデッドキーは使わない。打てない文字が含まれていたら、何も送らずにビープで知らせる
- **AppleScript から常駐への受け渡し**: FIFO（名前付きパイプ）を使う。置き場所はユーザーごとの一時ディレクトリ（`$(getconf DARWIN_USER_TEMP_DIR)modeless-type.fifo`）。常駐が終了する時（SIGTERM / SIGINT）に削除し、FIFO が無ければ AppleScript は「常駐していない」と判断してビープを鳴らす。`/tmp` は他のユーザーも書き込めるので避けた。一時ディレクトリは、起動元によって値が違う環境変数 `TMPDIR` ではなく、`confstr` / `getconf DARWIN_USER_TEMP_DIR` で求める。ログも同じ理由で `~/Library/Logs/` に置く
- **範囲取得は `contents` の全体取得のまま**: `range of selection` は grapheme cluster 単位、`characters` 要素の添字は UTF-16 単位で、絵文字や結合文字があるとずれる。`characters ... of contents` による部分取得は、このずれがあるので採用していない
- **性能**: 変換開始までは、Ctrl+J の AppleScript 開始から数十〜百数十 ms ＋ Swift 内の待ち（約 0.2 秒）。約 220 万文字の文書の末尾でも、AppleScript 側は約 1 秒
- **AppleScript の注意**: CotEditor のスクリプトメニューから実行すると、`length of 文字列` が -1728 で失敗した。文字数は計算で求めている
- **Swift だけで完結させる案**: AX（アクセシビリティ API）でフォーカス中のテキスト欄から直接取得する方式なら、エディタ非依存にできそう。未実装

## ライセンス

Zero-Clause BSD（[LICENSE](LICENSE)、日本語訳は [LICENSE-ja](LICENSE-ja)）
