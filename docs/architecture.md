# Ommateum — アーキテクチャ

根拠となる調査は [feasibility.md](feasibility.md) を参照。

## 基本構成

| 項目 | 選定 |
| --- | --- |
| 言語 / UI | Swift 6（既定アクター分離 = `MainActor`）+ AppKit。SwiftUIは設定画面など周辺のみで使う可能性あり |
| 最低OS | macOS 14 Sonoma |
| 配布形態 | Sandboxなし + Hardened Runtime（Developer ID想定） |
| Bundle ID | `com.example.Ommateum`（仮。配布前に変更すること） |
| プロジェクト | `Ommateum.xcodeproj`（フォルダ同期グループ。`Ommateum/` 以下のファイルは自動でビルド対象） |
| 外部ライブラリ | なし |

## レイヤ

```
Ommateum/
  App/          AppDelegate、メインメニュー、設定（UserDefaults）
  Model/        純粋なデータ型（Codable）。UI非依存で単体テスト対象
                  SplitTree     … 分割ツリー（leaf = ペインID）と正規化・挿入・削除
                  TabState      … タブ1つ分の状態（場所・表示モード・ソート・履歴）
                  WorkspaceSnapshot … 保存形式（version付きJSON）
                  FileItem      … 一覧の1行分のメタデータ
  Services/     I/O担当。メインスレッドを塞がない
                  DirectoryLoader   … 非同期のディレクトリ列挙
                  DirectoryMonitor  … DispatchSourceによる変更監視
                  FileOperations    … コピー/移動/複製/ゴミ箱/改名/新規フォルダ + Undo + 競合確認
                  WorkspaceStore    … ワークスペースとセッションの保存・読込
                  SidebarStore      … サイドバーのグループ・登録サーバ・表示設定の保存
  UI/
    Window/     MainWindowController（ツールバー、サイドバー + ワークスペースの NSSplitViewController）
    Sidebar/    SidebarViewController（NSOutlineView ソースリスト）
    Workspace/  WorkspaceViewController（SplitTree → 入れ子 NSSplitView）
                PaneViewController（タブバー + アクティブタブの内容）
                TabBarView（タブの描画・並べ替え・他ペインへのドラッグ）
                DropOverlayView（分割ドロップのプレビュー）
    Browser/    FileBrowserViewController（1タブ = 1インスタンス。履歴・表示モード切替）
                ListViewController（NSOutlineView）/ IconViewController（NSCollectionView）
                ColumnViewController（NSBrowser）
```

## 状態管理の方針

- **分割レイアウト**: `SplitTree`（値型）が正。`leaf(paneID)` / `split(axis, children, fractions)`。
  分割・移動・閉じる操作は純粋関数でツリーを更新 → `WorkspaceViewController` が `NSSplitView` 階層を再構築する。
  `PaneViewController` はペインIDで保持し再利用するため、再構築してもタブの状態（スクロール位置以外）は失われない。
  境界のリサイズ結果は再構築・保存の直前に `NSSplitView` から `fractions` へ書き戻す。
- **タブ**: `FileBrowserViewController` が実行時状態を持ち、保存時に `TabState` へスナップショットする。
  タブの他ペインへの移動はビューコントローラごと移すので状態が保たれる。
- **ワークスペース**: `WorkspaceSnapshot`（`version`、ウィンドウ frame、`SplitTree`、`[paneID: PaneState]`、
  アクティブペイン、サイドバーの開閉・幅）を JSON で `~/Library/Application Support/Ommateum/` に保存。
  読込時に存在しない場所は、存在する最も近い親へフォールバックし、タブ上に通知を出す。

## イベント設計の要点

- **空白ダブルクリック**: 一覧ビューのサブクラスで `mouseDown` を受け、`clickCount == 2` かつヒットした行/項目がない場合のみ
  「親へ移動」を発火。スクロールバーやヘッダーは別ビューのため対象外。設定で無効化可能。
- **ドラッグの型分離**: タブ = `com.ommateum.tab`、ファイル = `public.file-url`。
  ペインのドロップ受け付けは `com.ommateum.tab` のみ、一覧のドロップ受け付けはファイルURLのみ。
- **アクティブペイン**: 最初のレスポンダーを含むペインをアクティブとし、ツールバー・サイドバー・メニュー操作の対象にする。
  非アクティブペインはタブバーを淡色化する程度の控えめな表示。

## 拡張（ファイルアクション）

Dropbox「コピーを転送」のような外部連携は、ブラウザやメニューのコードに直接書かず **アクション** として追加する。

- `FileActionProvider`（`Ommateum/Actions/FileAction.swift`）: 選択項目（`FileActionContext`）を受け取り、
  使える `FileAction`（タイトル＋実行処理）を返す。`FileActionRegistry` に登録されたプロバイダの結果が、
  コンテキストメニューの「共有」の下と「ファイル ▸ アクション」に並ぶ。
- 組み込み: `OpenInTerminalActionProvider`、`DropboxTransferActionProvider`（Dropbox の共有拡張を直接実行。未インストールなら何も返さない）。
  新しい連携は `FileActionProvider` を実装した型を1ファイル追加し、`FileActionRegistry.shared` に加えるだけでよい。
- ユーザー定義: `CustomActionsProvider` が `~/Library/Application Support/Ommateum/actions.json` を読み、
  アプリを再ビルドせずにアクションを追加できる（スクリプト / ショートカット / 共有サービス）。書式は [actions.md](actions.md)。
  ファイルの更新日時が変わったときだけ読み直すので、編集は次にメニューを開いたときに反映される。
- **採用しなかった方式: 実行時に読み込むプラグイン（.bundle / dylib）**。Hardened Runtime のライブラリ検証により、
  同じ Team ID で署名されていないコードは読み込めない。読み込むには `disable-library-validation` で検証を外す必要があり、
  任意のコードがアプリ内で動くことになるため採用しない。外部の処理は別プロセス（スクリプト・ショートカット）か、
  macOS の公開拡張（共有拡張・サービス）経由で呼ぶ。

## コピーの実行

`FileManager.copyItem` は進捗も中止もできないため、`FileCopier` が `copyfile(3)` を使う（属性・拡張属性・シンボリックリンクを保持し、APFS では複製）。
進捗は `TransferProgress`（ロック付き）に書き、`TransferCenter` が 0.1 秒ごとに読んで通知する。0.4 秒以内に終わる操作は一覧に載せない。
各ウインドウのツールバーは、一覧が空でない間だけ `TransferIndicatorButton`（全操作の合計のリング）を表示ボタンの左に挿入し、クリックで操作ごとの吹き出しを開く。速度は `TransferSpeedMeter` が直近 3 秒の差分から出す。
別ボリュームへの移動はコピー完了後に元を削除する。
