# urlqueue

「あとで開く URL」をためておく macOS アプリ。シェルから URL を放り込み、
メニューバーかウィンドウの一覧からクリックしてデフォルトブラウザで開く。開いたものは一覧から消える。

- メニューバー常駐 + 通常ウィンドウの両方
- 引数で URL を受け取る（`urlqueue https://example.com`）
- 一覧のクリックでデフォルトブラウザで開き、同時に削除
- 開かずに削除も可能（行の × / 右クリック / `urlqueue remove`）
- GUI と CLI は `~/.urlqueue/queue.json` を共有。アプリ未起動でもキューに溜まる
- **自分自身をデフォルトブラウザにできる** — あらゆるリンクのクリックがキューに入る

依存ライブラリなし（Swift + SwiftUI + AppKit のみ）。

## ビルドとインストール

```sh
./build.sh install
```

- `dist/UrlQueue.app` を組み立て、`/Applications` に配置
- CLI を `~/.local/bin/urlqueue` にシンボリックリンク

`~/.local/bin` が PATH にない場合:

```fish
fish_add_path ~/.local/bin
```

```bash
export PATH="$HOME/.local/bin:$PATH"
```

ビルドだけなら `./build.sh`。配置先は環境変数で変えられる:

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `APP_DIR` | `/Applications` | `.app` の配置先 |
| `BIN_DIR` | `~/.local/bin` | CLI シンボリックリンクの置き場所 |
| `UNIVERSAL` | `0` | `1` で arm64 + x86_64 ユニバーサルバイナリ |

初回起動時、ad-hoc 署名のため Gatekeeper の確認が出ることがある。
その場合は Finder で `UrlQueue.app` を右クリック →「開く」。

## 使い方

```sh
urlqueue https://example.com              # 追加してアプリを前面に出す
urlqueue add a.example.com b.example.com  # 複数まとめて追加
urlqueue add https://example.com --no-open  # アプリを起動せず追加だけ
pbpaste | urlqueue add -                  # 標準入力から 1 行 1 URL
urlqueue list                             # 一覧（番号は 1 始まり）
urlqueue open                             # 先頭を開いて削除
urlqueue open 3                           # 3 番目を開いて削除
urlqueue open --all                       # すべて開いて削除
urlqueue remove 2 4                       # 開かずに削除
urlqueue clear                            # 全削除
urlqueue path                             # queue.json のパス
urlqueue gui                              # GUI 起動
urlqueue --help
```

引数なしで起動すると GUI が立ち上がる（`.app` からの起動と同じ）。

スキームを省略した `example.com` は `https://` を補う。
URL として解釈できない引数はスキップし、終了コード 1 を返す。

### 開く先のブラウザ

```sh
urlqueue browser              # 現在の開く先
urlqueue browser --list       # 候補一覧
urlqueue browser Chrome       # 名前 / bundle ID / .app パスで指定
urlqueue browser --system     # システムのデフォルトに戻す
```

設定は `~/.urlqueue/config.json` に保存される。未設定ならシステムのデフォルトブラウザを使う。

### GUI の操作

| 操作 | 結果 |
| --- | --- |
| 行をクリック | デフォルトブラウザで開いて一覧から削除 |
| 行の × ボタン | 開かずに削除 |
| 行を右クリック | 開いて削除 / URL をコピー / 削除 |
| 「すべて開く」 | 全件開いて一覧を空にする |
| 「すべて削除」 | 確認の上、開かずに全削除 |
| メニューバーのアイコン | ポップオーバーで一覧（件数をバッジ表示） |
| ⌘0 | ウィンドウを表示 |
| ⌘W | ウィンドウを閉じる（メニューバーには残る） |
| ⌘Q | 終了 |

ウィンドウを閉じてもメニューバーに常駐し続ける。

## デフォルトブラウザとして使う

このアプリ自身を http/https のハンドラにすると、**どのアプリでリンクをクリックしても
ブラウザが開かず、キューに溜まる**ようになる。あとでまとめて片付けたいときに便利。

```sh
urlqueue default-browser              # 現在のハンドラを表示
urlqueue default-browser set          # このアプリをデフォルトブラウザにする
urlqueue default-browser unset Chrome # Chrome に戻す
```

`set` / `unset` は macOS の確認ダイアログを出す。**ダイアログをクリックするまでコマンドは
返らない**（最大 10 分待つ）。GUI のフッタにある「デフォルトブラウザにする」ボタンでも同じことができる。

ダイアログは `CoreServicesUIAgent` が表示しているため、コマンドを途中で `Ctrl-C` しても
ダイアログは画面に残る。放置すると重なっていくので、出たらその場で答えるのがよい。

### 無限ループについて

自分がデフォルトブラウザになると、`NSWorkspace.open` は自分自身に戻ってくる。
そのままだと「開く → キューに入る → 開く」で永遠に終わらないので、開く先を
デフォルトブラウザとは独立に持っている。ガードは 3 段:

| 状況 | 挙動 |
| --- | --- |
| `urlqueue browser` で自分自身を指定 | 拒否（exit 2） |
| `config.json` に自分自身が書かれている | 無視してシステムのデフォルトにフォールバック |
| 開く先がどうしても解決できない | **開かずにキューに残す**（URL を失わない） |

`default-browser set` は乗っ取る直前に、その時点のデフォルトブラウザを
開く先として `config.json` に自動保存する。つまり Chrome がデフォルトの状態で `set` すれば、
以降は「リンク → キュー → クリック → Chrome」という流れになる。

### 元に戻す

```sh
urlqueue default-browser unset Chrome
```

システム設定 > デスクトップとDock > デフォルトのWebブラウザ からでも戻せる。
アプリを消す前に必ず戻すこと（ハンドラが存在しないとリンクが開けなくなる）。

## 仕組み

CLI と GUI は同一バイナリ。引数の有無でモードを切り替える。

```
他アプリのリンククリック ──LaunchServices──┐   (デフォルトブラウザにした場合)
                                          ↓
urlqueue <URL>  ──書き込み──>  ~/.urlqueue/queue.json  <──監視── UrlQueue.app (GUI)
                                        ↑                          │
                                 flock(2) で排他                   │ クリック
                                 rename(2) で原子的差し替え         ↓
                                                            config.json の
                                                            openWithBundleID
                                                            （例: Chrome）
```

GUI は保存ディレクトリを `DispatchSource`（vnode）で監視しているので、
別プロセスの変更が即座に一覧へ反映される。加えて CLI が
`DistributedNotificationCenter` で変更を通知し、反映を早めている。

`config.json` の形:

```json
{ "version": 1, "openWithBundleID": "com.google.Chrome" }
```

`queue.json` の形:

```json
{
  "version": 1,
  "items": [
    { "id": "…UUID…", "url": "https://example.com", "addedAt": "2026-11-05T02:00:00Z" }
  ]
}
```

## 保存先の変更

`URLQUEUE_DIR` で保存ディレクトリを差し替えられる（既定 `~/.urlqueue`）。

```sh
URLQUEUE_DIR=/tmp/q urlqueue list
```

注意: `open -a` 経由で起動する GUI はシェルの環境変数を引き継がないため、
`URLQUEUE_DIR` を使うと CLI と GUI が別のキューを見ることになる。
基本的にはテスト用。

## 開発

```sh
swift build                                    # デバッグビルド
URLQUEUE_DIR=/tmp/q swift run urlqueue list    # CLI を直接実行
swift run urlqueue gui                         # GUI を直接実行
```

`.app` バンドルに入っていないバイナリから `urlqueue <URL>` を実行した場合、
アプリの前面化はスキップされる（バンドルを辿れないため）。
