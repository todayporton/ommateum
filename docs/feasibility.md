# Ommateum — 技術調査（Phase 1）

調査日: 2026-10-30
検証環境: macOS 26.2 (25C56) / Apple Silicon (arm64) / Xcode 26.6 / Swift 6.3.3 / Dropbox 277.4.4974

各項目は「検証方法 → 結果 → 制約 → 採用方針／代替案」の順に記す。
**状態** は `検証済` / `文献ベース（未実験）` / `未検証` のいずれか。

---

## 1. Finder風ファイルブラウザの標準UI再利用範囲

**状態: 文献ベース（未実験）**

- 検証方法: AppKit公開APIの確認。
- 結果:
  - Finderのファイル一覧ビューを他アプリへ埋め込む公開APIは存在しない。`NSOpenPanel` / `NSSavePanel` は
    モーダル（またはシート）の専用UIであり、任意のビュー階層に組み込んで常設のブラウザとしては使えない。
  - 再利用できるのは部品レベル:
    - 一覧: `NSOutlineView`（リスト表示。Finderのリストと同じく階層展開が可能）、`NSCollectionView`（アイコン表示）、
      `NSBrowser`（カラム表示）。
    - アイコン: `NSWorkspace.icon(forFile:)`、サムネイル: `QLThumbnailGenerator`（QuickLookThumbnailing）。
    - プレビュー: `QLPreviewPanel`（Spaceキーでの Quick Look。Finderと同じパネル）。
    - ファイル操作: `FileManager`、`NSWorkspace.recycle(_:)`（ゴミ箱、"戻す" 情報付き）、`NSWorkspace.open`、
      `NSWorkspace.activateFileViewerSelecting`（Finderで表示）、`NSFileCoordinator`。
    - メタデータ: `URLResourceValues`（`localizedName`、`tagNames`、`isHidden`、`ubiquitousItem*` 等）。
    - 監視: `DispatchSource.makeFileSystemObjectSource`（ディレクトリ単位）または FSEvents。
- 採用方針: 一覧は独自実装（AppKit部品）。外観の模倣より、選択・フォーカス・キーボード・ドラッグ・ファイル操作の自然さを優先する。

## 2. Dropbox右クリックメニューの再利用可能性

**状態: 検証済（環境確認）＋文献ベース**

- 検証方法: `pluginkit -mAvvv`、`Info.plist` の `NSServices` / `CFBundleURLTypes`、ホームの実フォルダ確認、
  `URLResourceValues` の ubiquitous 系キー取得実験（`swift` スクリプト）。
- 結果:
  - Dropbox.app は次の拡張を持つ: `garcon.appex`（**Finder Sync** 拡張 — Finderの右クリックメニューとバッジを提供）、
    `DropboxFileProvider.appex`（File Provider）、`DropboxTransferExtension.appex`。
  - 本環境のDropboxフォルダ（個人用とチーム用の2つ）は**通常のディレクトリ**であり
    File Provider（`~/Library/CloudStorage`）配下ではない（`~/Library/CloudStorage` は空）。
    `isUbiquitousItem` 等は `nil`。= 旧来の同期方式。
  - Dropbox.app は `NSServices` を宣言していない。URLスキーム `dropbox-client` は存在するが**非公開**で仕様不明。
  - Finder Sync拡張のメニューは `FIFinderSync.menu(for:)` を**Finderだけが**呼び出す仕組みで、
    他アプリから取得・実行する公開APIはない。
  - ただし `DropboxTransferExtension.appex` は **共有拡張**（`com.apple.share-services`、ファイル・フォルダ対応）であり、
    公開API `NSSharingService` / `NSSharingServicePicker` から呼び出せる（2026-10-30 追加調査で確認。当初の調査で見落としていた）。
    Finder の Dropbox メニューの「コピーを転送」はこの Dropbox Transfer に相当する。
- 制約: Dropbox固有操作（共有リンクのコピー、バージョン履歴、オンラインのみ保存 等）を Ommateum から直接呼ぶ公開手段はない。
  非公開URLスキームやプロセス間通信の解析は行わない（指示書の方針）。
- 採用方針／代替案:
  1. **「Finderで表示」**（`NSWorkspace.activateFileViewerSelecting`）をコンテキストメニューとショートカット（⌥⌘R 相当は Finder では
     別用途のため、メニュー項目のみ＋任意ショートカット）で提供し、Finder上でDropboxメニューを使ってもらう。— 実装対象
  2. **macOS Services / Quick Actions**: ファイルURLを送る `validRequestor(forSendType:returnType:)` を実装し、
     「サービス」メニューから他アプリ（Automator / ショートカットのQuick Action含む）を利用可能にする。— Phase 5
  3. **File Provider 方式のDropbox**（今後Dropboxが移行した場合）: `ubiquitousItemDownloadingStatus` 等の公開キーで
     プレースホルダー／未ダウンロード状態を表示し、`FileManager.startDownloadingUbiquitousItem` / `evictUbiquitousItem`
     でダウンロード／オンラインのみ化を提供できる可能性がある。— 未検証（本環境はFile Provider方式でないため）
  4. **Dropbox Transfer（「コピーを転送」）**: コンテキストメニューとファイルメニューの「コピーを転送（Dropbox Transfer）…」で
     共有拡張を直接実行する。特定サービスを直接呼ぶ公開手段は非推奨の `NSSharingService.sharingServices(forItems:)` のみのため、
     これを使う（Dropbox未インストール時は項目を出さない）。標準の「共有」サブメニューも併設。— 実装済み
  5. Dropbox公式Web API（OAuth）による共有リンク作成は技術的には公開APIだが、認証基盤とネットワーク依存が大きく
     「最小限の便利機能」方針に反するため当面採用しない。

## 3. Finderサイドバーの項目・順序・設定の取得可能性

**状態: 検証済（実験）**

- 検証方法: `~/Library/Application Support/com.apple.sharedfilelist/*.sfl4` を `NSKeyedUnarchiver` でデコードし、
  各 `Bookmark` を `URL(resolvingBookmarkData:)` で解決する Swift スクリプトを実行。
- 結果:
  - `com.apple.LSSharedFileList.FavoriteItems.sfl4` から「よく使う項目」の**項目と順序**、および
    `com.apple.LSSharedFileList.ItemIsHidden` プロパティ（非表示）を読み取れた。
  - `FavoriteVolumes.sfl4` からボリューム／コンピュータ／iCloud等の特殊項目（`SpecialItemIdentifier`）を読めたが、
    過去に接続したボリューム（未解決Bookmark）も大量に含まれ、Finderの実際の表示とは対応付けが自明ではない。
  - 公式の `LSSharedFileList` C API は macOS 10.11 で非推奨、`kLSSharedFileListFavoriteItems` の公開代替APIはない。
- 制約:
  - `.sfl4` は**非公開フォーマット**（拡張子は sfl → sfl2 → sfl3 → sfl4 と過去に変わっている）。将来のOSで壊れ得る。
  - App Sandbox 下では `~/Library/Application Support/com.apple.sharedfilelist` を読めない。
  - 変更検知はファイル監視で可能だが、書き戻し（Ommateum→Finder）は破損リスクがあるため行わない。
- 採用方針:
  - **独自サイドバー（手動編集可）を正**とする。初期値はFinder既定に近い構成（AirDrop等の特殊項目は除外）。
  - 「Finderのよく使う項目を読み込む」機能を**実験的・読み取り専用**で提供する（Phase 5）。読めない場合は黙って既定値。
  - 「場所」（ボリューム、ネットワーク）は公開APIの `FileManager.mountedVolumeURLs` と
    `NSWorkspace.didMount/didUnmount` 通知で構成し、Finderとは独立に正しく更新する。
  - 「場所」にはホーム、コンピュータ（`/Volumes` を表示）、iCloud Drive、クラウドストレージ、ボリューム、ゴミ箱を置き、
    「設定 ▸ サイドバー」のチェック（種類ごと）と右クリック（項目ごと）で隠せる。Ommateum 独自の設定で、Finder の設定とは連動しない。
  - **AirDrop とネットワークは置かない。** どちらもフォルダではなく、Finder 内の画面を表示する公開 API がない
    （`/Network` は空のことがある）。AirDrop は共有メニューから使える。
  - 接続中の共有はサーバ名でまとめる（`volumeURLForRemounting` のホスト名から取得）。Finder と違い、未接続の共有は一覧できない
    （公開 API がない）。共有が1つならサーバの行をクリックでその中身を開き、複数なら行を展開する。
  - 実現できない範囲: Finderサイドバーとの**双方向・リアルタイムの完全同期**、Finderで設定したセクション表示状態の完全再現。

## 4. タブ移動と縦横自由なネスト分割

**状態: 検証済（Phase 3 で実装し、実アプリでタブの移動・端へのドロップによる分割・空ペイン除去を確認）**

- 実装上の注意（検証で判明）: タブのボタンを mouse-down 時に作り直すとドラッグが開始されない。
  タブ構成が同じなら既存ボタンを更新する。分割比率は「初回だけ適用」では再起動ごとにずれるため、
  リサイズのたびに比率から配置し、ユーザーが境界をドラッグした時だけ比率を更新する。

- `NSSplitView` は1方向の分割のみだが、入れ子にすることで任意のネストが可能。
  分割状態はモデル側の再帰的 Split Tree（`split(axis, children, fractions)` / `pane`）を正とし、
  ビューはツリーから再構築する（状態保存・復元が容易）。
- タブのドラッグは独自 pasteboard type（`com.ommateum.tab`）で行い、ファイルのドラッグ（`public.file-url`）と型で区別する。
- ドロップ領域判定: ペインの端（上下左右 各25%）→ 分割、中央／タブバー → 移動。ドラッグ中はオーバーレイでプレビュー。
- タブが0になったペインは除去し、子が1つのSplitは親へ畳み、同方向の入れ子は平坦化して正規化する。
  正規化はモデルの純粋関数として単体テストする。

## 5. Sandbox、ファイルアクセス、クラウドプロバイダとの互換性

**状態: 文献ベース**

- ファイラーは任意の場所へのアクセスが本質であり、App Sandbox ではユーザー選択ごとに security-scoped bookmark が必要で
  使い勝手がFinderから大きく離れる。Finderサイドバー読み込み（§3）もSandbox下では不可能。
- 採用方針: **Sandboxなし・Hardened Runtime有効**、Developer ID配布を想定（Mac App Store配布は対象外）。
  - 保護されたフォルダ（デスクトップ、書類、ダウンロード、リムーバブル、ネットワーク）へのアクセス時はOSのTCC確認が出る。
    必要に応じ「フルディスクアクセス」を案内する。アクセス拒否はエラー表示で扱いクラッシュしない。
  - ワークスペースのURLはパス＋（取得できれば）通常のbookmarkデータで保存し、移動・改名に追従を試みる。
    Sandboxなしのため security-scoped bookmark は不要。
- クラウド（iCloud Drive / File Provider）: 列挙は通常の `FileManager` で可能。`ubiquitousItemDownloadingStatus` で
  未ダウンロード表示、開く際はOSが自動ダウンロード。サムネイル生成は未ダウンロードファイルに対して要求しない。

## 6. 最低対応macOSバージョン

**提案: macOS 14 Sonoma 以降**

- 理由: Swift Concurrency・`Observation` 等の現行APIを無理なく使える一方、Sonomaは2023年リリースで利用者が多い。
  macOS 15/26 固有APIは必須としない（必要なら `#available` で分岐）。
- Apple Silicon ネイティブ（arm64）。Intel（x86_64）もビルド設定上は除外しない。

## 7. 外部ライブラリ

- なし（Apple標準フレームワークのみ）。
- Xcodeプロジェクトは Xcode 16 以降の「フォルダ同期グループ（`PBXFileSystemSynchronizedRootGroup`）」を使い、
  ファイル追加時に `project.pbxproj` の編集を不要にする。xcodegen 等の生成ツールは導入しない。
