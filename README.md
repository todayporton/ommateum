# Ommateum

A native macOS file manager for looking at several folders at once.
It keeps the feel of Finder as much as possible and adds three things:

1. **Double-click an empty area** of a listing to go to the parent folder
2. **Split and rearrange panes freely by dragging tabs**, like editor groups in VS Code (each pane has its own tabs)
3. Save and restore the layout, folders and tabs as **named workspaces**

The user interface is in Japanese. Menu and setting names below are given in Japanese, with English in parentheses.

## Building

- Requirements: macOS 14 or later, Xcode 16 or later (tested with Xcode 26.6 / macOS 26.2 / Apple Silicon)
- No third-party libraries

```sh
open Ommateum.xcodeproj            # then ⌘R in Xcode
# or from the command line
xcodebuild -project Ommateum.xcodeproj -scheme Ommateum -derivedDataPath build build
xcodebuild -project Ommateum.xcodeproj -scheme Ommateum -derivedDataPath build test
open build/Build/Products/Debug/Ommateum.app
```

The bundle identifier is `online.todayporton.ommateum`.
The app does not use App Sandbox (see [docs/feasibility.md](docs/feasibility.md) §5 for why).

Settings, the session and workspaces are stored as JSON in `~/Library/Application Support/Ommateum/`.
The environment variable `OMMATEUM_SUPPORT_DIR` points the app at another location instead (for testing the UI without touching real data).

## Main controls

| Action | Key / mouse |
| --- | --- |
| Back / forward | Mouse side buttons / ⌘[ / ⌘] |
| Parent folder | Double-click an empty area (can be turned off in settings) / ⌘↑ |
| Open / open in a new tab | Double-click, ⌘↓, ⌘O / ⌘-double-click |
| Rename | Return |
| Quick Look | Space, ⌘Y |
| New folder / duplicate / move to Trash | ⇧⌘N / ⌘D / ⌘⌫ |
| Copy / paste / move here | ⌘C / ⌘V / ⌥⌘V |
| Undo / redo | ⌘Z / ⇧⌘Z |
| View | ⌘1 icons / ⌘2 list / ⌘3 columns / ⌘4 gallery |
| Search | ⌘F (this folder, or including subfolders) |
| Change shortcuts | 設定 ▸ ショートカット (Settings ▸ Shortcuts) |
| Get info / make alias | ⌘I / ⌃⌘A |
| New tab / close tab | ⌘T / ⌘W |
| Split right / split down / close pane | ⌘\ / ⇧⌘\ / ⌥⇧⌘W |
| Center a divider | Double-click the divider between panes |
| Next / previous pane | ⌥⌘` / ⌥⇧⌘` |
| Move or split with a tab | Drag a tab onto another pane's tab bar (move), onto a pane's edge (split), or out of the window (new window) |
| Save workspace / save as | ⌘S / ⇧⌘S; open one from the menu (hold ⌥ to open it in a new window) |
| Show hidden files | ⇧⌘. |
| Dropbox "Send a copy" | Context menu / ファイル ▸ アクション (File ▸ Actions) |

## Release build

```sh
scripts/release.sh                                  # ad-hoc signed (for this Mac)
OMMATEUM_BUNDLE_ID=... DEVELOPER_ID="Developer ID Application: ..." NOTARY_PROFILE=... scripts/release.sh
```

## Custom actions

You can add your own commands (scripts, Shortcuts, sharing services) to the context menu.
ファイル ▸ アクション ▸ アクションを編集… (File ▸ Actions ▸ Edit Actions…) opens `actions.json`. The format is described in [docs/actions.md](docs/actions.md).

## Status

The documents under `docs/` are written in Japanese.
Details are in [docs/status.md](docs/status.md); the design is in [docs/architecture.md](docs/architecture.md),
the technical research in [docs/feasibility.md](docs/feasibility.md), and the requirements in [docs/instruction.md](docs/instruction.md).

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Technical research and design | Done |
| 2 | Single-pane file manager | Main features implemented and checked (a few are not implemented yet) |
| 3 | Tabs and splits | Implemented and checked |
| 4 | Workspaces | Implemented and checked |
| 5 | Finder integration and finishing | Implemented. Some parts still await checks with real use (see "未検証" in status.md). Release signing awaits a certificate |
