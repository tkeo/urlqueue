# urlqueue

「あとで開く URL」をためておく macOS アプリ。シェルから URL を放り込み、
メニューバーかウィンドウの一覧からクリックしてデフォルトブラウザで開く。開いたものは一覧から消える。

- メニューバー常駐 + 通常ウィンドウの両方
- 引数で URL を受け取る（`urlqueue https://example.com`）
- 一覧のクリックでデフォルトブラウザで開き、同時に削除
- 開かずに削除も可能（行の × / 右クリック / `urlqueue remove`）
- GUI と CLI は `~/.urlqueue/queue.json` を共有。アプリ未起動でもキューに溜まる

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

## 仕組み

CLI と GUI は同一バイナリ。引数の有無でモードを切り替える。

```
urlqueue <URL>  ──書き込み──>  ~/.urlqueue/queue.json  <──監視── UrlQueue.app (GUI)
                                        ↑
                                 flock(2) で排他、rename(2) で原子的差し替え
```

GUI は保存ディレクトリを `DispatchSource`（vnode）で監視しているので、
別プロセスの変更が即座に一覧へ反映される。加えて CLI が
`DistributedNotificationCenter` で変更を通知し、反映を早めている。

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
