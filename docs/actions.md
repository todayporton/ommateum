# カスタムアクション（actions.json）

右クリックメニューと「ファイル ▸ アクション」に、自分用のコマンドを追加できます。アプリの再ビルドは不要です。

- 場所: `~/Library/Application Support/Ommateum/actions.json`
  （「ファイル ▸ アクション ▸ アクションを編集…」で開けます。ファイルがなければ例を作成して開きます）
- 保存すると、次にメニューを開いたときから反映されます。
- 書式が壊れているときは、メニューに「actions.json を読み込めません…」が出ます（選ぶと原因を表示）。
- アクションは**選択した項目すべて**が条件に合うときだけ表示されます。
- スクリプトなどと一緒にフォルダ1つで配りたいときは、プラグインにできます（[plugins.md](plugins.md)）。
- 設定 ▸ プラグイン で、actions.json 全体の有効・無効を切り替えられます。

## 例

```json
{
  "version": 1,
  "actions": [
    {
      "title": "ターミナルで開く",
      "type": "script",
      "command": "/usr/bin/open",
      "arguments": ["-a", "Terminal", "{files}"],
      "appliesTo": "folders"
    },
    {
      "title": "VS Code で開く",
      "type": "script",
      "command": "/usr/bin/open",
      "arguments": ["-a", "Visual Studio Code", "{files}"]
    },
    {
      "title": "画像を縮小",
      "type": "shortcut",
      "name": "画像を縮小",
      "extensions": ["png", "jpg", "jpeg", "heic"]
    },
    {
      "title": "AirDrop で送る",
      "type": "shareService",
      "name": "AirDrop"
    }
  ]
}
```

## 項目

| キー | 必須 | 内容 |
| --- | --- | --- |
| `title` | ✓ | メニューに表示する名前 |
| `type` | ✓ | `script` / `shortcut` / `shareService` |
| `command` | script | 実行ファイルのパス（`~` 可）、またはコマンド名（PATH から探す） |
| `arguments` | | script の引数。省略時は選択項目のパスを並べる |
| `name` | shortcut / shareService | ショートカット名 / 共有サービス名（「共有」メニューに出る名前。例: `AirDrop`, `Dropbox Transfer`） |
| `appliesTo` | | `any`（既定）/ `files` / `folders` |
| `extensions` | | 対象の拡張子（大文字小文字を区別しない）。指定するとフォルダには出ない |
| `whenNoSelection` | | `true` なら何も選択していないときも表示し、表示中のフォルダを対象にする |
| `shortcut` | | キーボードショートカット。例: `"cmd+shift+k"`。`cmd` か `ctrl` が必須 |

`arguments` の置き換え:

- `{files}` — 引数まるごとこれだけのとき、選択項目のパスを1つずつ別の引数として展開
- `{dir}` — 表示中のフォルダのパス（引数の一部にも使える）

## 動作

- `script` はシェルを通さずに実行します（パスに空白や記号があっても安全に渡ります）。
  シェルの機能が必要なら `"command": "/bin/zsh", "arguments": ["-c", "…", "_", "{files}"]` のようにします。
  作業ディレクトリは表示中のフォルダです。
- `shortcut` は `shortcuts run <name> --input-path <各項目>` で実行します。
- 実行はバックグラウンドで行い、終了コードが 0 以外ならエラー出力の末尾を表示します。標準出力は捨てます。
- 実行環境は Ommateum から起動したプロセスのもので、ターミナルの PATH 設定（`.zshrc` 等）は読み込まれません。
  Homebrew のコマンドなどはフルパス（例: `/opt/homebrew/bin/…`）で指定してください。
