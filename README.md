# Ommateum

複数のディレクトリを同時に見渡すための macOS ネイティブファイラー。
Finder の使用感をできるだけ保ち、次の3点を加えます。

1. 一覧の**空白部分をダブルクリック**すると親フォルダへ移動
2. VS Code のエディターグループのように、**タブのドラッグで縦横自由にペインを分割・再配置**（各ペインが独立したタブを持つ）
3. 画面構成・フォルダ・タブを**名前付きワークスペース**として保存・復元

## ビルド

- 要件: macOS 14 以降、Xcode 16 以降（検証: Xcode 26.6 / macOS 26.2 / Apple Silicon）
- 外部ライブラリなし

```sh
open Ommateum.xcodeproj            # Xcode で ⌘R
# またはコマンドライン
xcodebuild -project Ommateum.xcodeproj -scheme Ommateum -derivedDataPath build build
xcodebuild -project Ommateum.xcodeproj -scheme Ommateum -derivedDataPath build test
open build/Build/Products/Debug/Ommateum.app
```

Bundle ID は `online.todayporton.ommateum` です。
App Sandbox は使用していません（理由は [docs/feasibility.md](docs/feasibility.md) §5）。

設定・セッション・ワークスペースは `~/Library/Application Support/Ommateum/` に JSON で保存されます。
環境変数 `OMMATEUM_SUPPORT_DIR` で別の場所を指定できます（検証用。実データに触れずに UI を試すときに使用）。

## 主な操作

| 操作 | キー / マウス |
| --- | --- |
| 戻る / 進む | マウスのサイドボタン / ⌘[ / ⌘] |
| 親フォルダへ | 空白をダブルクリック（設定で無効化可）/ ⌘↑ |
| 開く / 新規タブで開く | ダブルクリック, ⌘↓, ⌘O / ⌘ダブルクリック |
| 名前を変更 | Return |
| クイックルック | Space, ⌘Y |
| 新規フォルダ / 複製 / ゴミ箱 | ⇧⌘N / ⌘D / ⌘⌫ |
| コピー / ペースト / 移動ペースト | ⌘C / ⌘V / ⌥⌘V |
| 取り消す / やり直す | ⌘Z / ⇧⌘Z |
| 表示切替 | ⌘1 アイコン / ⌘2 リスト / ⌘3 カラム / ⌘4 ギャラリー |
| 検索 | ⌘F（このフォルダ / サブフォルダも含む） |
| ショートカットの変更 | 設定 ▸ ショートカット |
| 情報を見る / エイリアス作成 | ⌘I / ⌃⌘A |
| 新規タブ / タブを閉じる | ⌘T / ⌘W |
| 右に分割 / 下に分割 / ペインを閉じる | ⌘\ / ⇧⌘\ / ⌥⇧⌘W |
| 仕切りを中央へ | ペイン間の仕切りをダブルクリック |
| 次/前のペイン | ⌥⌘` / ⌥⇧⌘` |
| タブを移動・分割 | タブを他ペインのタブバーへ（移動）、ペインの上下左右端へ（分割）、ウインドウ外へ（新規ウインドウ） |
| ワークスペース保存 / 名前を付けて保存 | ⌘S / ⇧⌘S、読み込みはメニューから（⌥で新規ウインドウ） |
| 隠しファイル表示 | ⇧⌘. |
| Dropbox「コピーを転送」 | 右クリック / ファイル ▸ アクション |

## 配布用ビルド

```sh
scripts/release.sh                                  # ad-hoc 署名（この Mac 用）
OMMATEUM_BUNDLE_ID=... DEVELOPER_ID="Developer ID Application: ..." NOTARY_PROFILE=... scripts/release.sh
```

## カスタムアクション

右クリックメニューに自分用のコマンド（スクリプト、ショートカット、共有サービス）を追加できます。
「ファイル ▸ アクション ▸ アクションを編集…」で `actions.json` を開きます。書式は [docs/actions.md](docs/actions.md)。

## 実装状況

詳細は [docs/status.md](docs/status.md)。設計は [docs/architecture.md](docs/architecture.md)、
技術調査は [docs/feasibility.md](docs/feasibility.md)、要件は [docs/instruction.md](docs/instruction.md)。

| Phase | 内容 | 状態 |
| --- | --- | --- |
| 1 | 技術調査・設計 | 完了 |
| 2 | 単一ペインのファイラー | 主要機能を実装・動作確認済み（一部未実装あり） |
| 3 | タブと分割 | 実装・動作確認済み |
| 4 | ワークスペース | 実装・動作確認済み |
| 5 | Finder統合・仕上げ | 実装済み。一部は実操作での確認待ち（status.md「未検証」）。配布用の署名は証明書待ち |
