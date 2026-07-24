# Wails File Explorer — Cross-Platform Port Plan

## Overview

Port the macOS File Explorer (Swift/SwiftUI) to Windows and Linux using Wails (Go backend + Svelte frontend). The Swift app in `app/` is the design reference and behavioral spec. This is a full rewrite, not a conversion — the SVG icons are the only directly reusable assets.

## Tech Stack

- **Backend:** Go (Wails v2)
- **Frontend:** Svelte
- **Target:** Windows first, then Linux
- **Icons:** Reuse bundled vscode-icons file SVGs and Catppuccin folder SVGs from `app/Resources/Icons/`

## Project Structure

```
wails/
├── main.go                     # Wails entry point
├── app.go                      # Go backend: file ops, navigation state
├── fileops.go                  # File operations: rename, delete, duplicate, new folder
├── settings.go                 # Settings persistence (JSON in platform config dir)
├── shortcuts.go                # Pinned folders persistence
├── colortags.go                # Color label system
├── foldericons.go              # Custom emoji folder icons
├── search.go                   # Directory search (platform-native or bundled tool)
├── wails.json
├── frontend/
│   ├── src/
│   │   ├── App.svelte          # Root layout: sidebar | files | right pane
│   │   ├── lib/
│   │   │   ├── keyboard.ts     # Keyboard handler (port from KeyboardHandler.swift)
│   │   │   ├── fileutils.ts    # Path helpers, extension detection, sort logic
│   │   │   ├── icons.ts        # Icon mapping (extension -> SVG name)
│   │   │   ├── types.ts        # TypeScript types (FileInfo, Settings, etc.)
│   │   │   └── stores.ts       # Svelte stores (selected item, current path, etc.)
│   │   ├── components/
│   │   │   ├── Sidebar.svelte          # Left sidebar (shortcuts, pinned, color tags)
│   │   │   ├── FileTree.svelte         # File listing (tree + flat modes)
│   │   │   ├── FileRow.svelte          # Single file/folder row
│   │   │   ├── Breadcrumb.svelte       # Path breadcrumb (flat mode)
│   │   │   ├── AncestorRow.svelte      # Tree mode ancestor rows
│   │   │   ├── ActionsPane.svelte      # Right pane actions
│   │   │   ├── PreviewPane.svelte      # Preview dispatcher
│   │   │   ├── TextPreview.svelte      # Text file preview
│   │   │   ├── ImagePreview.svelte     # Image preview
│   │   │   ├── ContextMenu.svelte      # Custom right-click menu
│   │   │   ├── Toast.svelte            # Toast notifications
│   │   │   ├── Settings.svelte         # Settings dialog
│   │   │   ├── SearchBar.svelte        # Search input + results
│   │   │   ├── KeyboardBar.svelte      # Bottom shortcut hints
│   │   │   └── EmojiPicker.svelte      # Emoji picker for folder icons
│   │   ├── assets/
│   │   │   └── icons/                  # Copy of app/Resources/Icons/*.svg
│   │   └── styles/
│   │       └── global.css              # Base styles, text style classes
│   ├── index.html
│   └── package.json
```

## Reference Files

When implementing, consult these Swift source files as the behavioral spec:

| Feature | Reference file |
|---------|---------------|
| Architecture overview | `doc/CODE_STRUCTURE.md` |
| Central state + navigation | `app/Models/FileExplorerManager.swift` |
| File operations | `app/Models/FileExplorerManagerFileOps.swift` |
| Search | `app/Models/FileExplorerManagerSearch.swift` |
| All keyboard shortcuts | `app/Views/KeyboardHandler.swift` |
| Settings schema | `app/Models/AppSettings.swift` |
| Pinned folders | `app/Models/ShortcutsManager.swift` |
| Color labels | `app/Models/ColorTagManager.swift` |
| Folder emoji icons | `app/Models/FolderIconManager.swift` |
| File icon mapping | `app/Models/IconProvider.swift` (extMap, nameMap, folderMap) |
| Selection system | `app/Models/FileItem.swift` |
| Root layout | `app/ContentView.swift` |
| Sidebar | `app/Views/ShortcutsView.swift` |
| File tree listing | `app/Views/FileTreeView.swift` |
| File table listing | `app/Views/FileTableView.swift` |
| Actions pane | `app/Views/ActionsPane.swift` |
| Context menu | `app/Views/CustomContextMenu.swift` |
| Preview dispatch | `app/Views/Preview/PreviewPane.swift` |
| Text styles | `app/Views/TextStyles.swift` |

## Phases

### Phase 1 — Scaffold + Basic File Browsing

**Go backend:**
- `ListDirectory(path string) -> []FileInfo` — returns files and dirs with name, size, modDate, isDirectory, isHidden, extension
- `NavigateTo(path string) -> DirectoryResult` — validate path, return contents
- `GetParent(path string) -> string`
- `GetHomeDir() -> string`
- `GetDesktopDir() -> string`
- `GetDownloadsDir() -> string`
- `OpenFile(path string)` — os.Open / exec.Command to open with default app
- `GetDrives() -> []DriveInfo` — Windows: enumerate drive letters; Linux: list /mnt, /media mounts

**Svelte frontend:**
- 3-pane layout with draggable dividers
- File list showing icon + name + size + date
- Click folder to navigate, click file to select
- Breadcrumb path bar
- Sort by name, type, modified, size
- Hidden files toggle

**FileInfo struct (Go):**
```go
type FileInfo struct {
    Name        string `json:"name"`
    Path        string `json:"path"`
    IsDirectory bool   `json:"isDirectory"`
    IsHidden    bool   `json:"isHidden"`
    Size        int64  `json:"size"`
    ModTime     int64  `json:"modTime"`
    Extension   string `json:"extension"`
}
```

### Phase 2 — Keyboard Navigation

Port the keyboard handler from `app/Views/KeyboardHandler.swift`. The Swift file uses macOS keyCodes; the Svelte version uses standard `KeyboardEvent.key` / `KeyboardEvent.code`.

**Mapping:**

| Swift keyCode | JS key | Action |
|---------------|--------|--------|
| 125 (Down) | ArrowDown | Select next |
| 126 (Up) | ArrowUp | Select previous |
| 123 (Left) | ArrowLeft | Navigate up |
| 124 (Right) | ArrowRight | Navigate into dir |
| 36 (Enter) | Enter | Rename |
| 51 (Backspace) | Backspace | Go back / Cmd+Backspace trash |
| 49 (Space) | Space | Toggle selection |
| 115 (Home) | Home | Select first |
| 119 (End) | End | Select last |
| 53 (Escape) | Escape | Return to files |
| 47 (Period) | . | Context menu |
| 45 (N) | Ctrl+Shift+N | New folder |
| 46 (M) | Ctrl+Shift+M | Context menu |
| 8 (C) | Ctrl+Shift+C | Copy selection here |
| 9 (V) | Ctrl+Shift+V | Move selection here |
| 2 (D) | Ctrl+Shift+D | Duplicate |
| 0 (A) | Ctrl+A | Select all |
| 3 (F) | Ctrl+F | Search |
| 17 (T) | Ctrl+T | Toggle tree/flat |
| 15 (R) | Ctrl+R | Refresh |
| letter | letter | Jump to file |

Note: On Windows/Linux use Ctrl instead of Cmd. The shortcut bar at the bottom should reflect this.

**Focus system:**
Tab cycles: Files -> Actions -> Sidebar -> Files.
Each mode captures different key events. See `KeyCaptureView.handleKeyDown` in the Swift source.

### Phase 3 — Sidebar

- **Built-in shortcuts:** Home, Desktop, Downloads (platform-appropriate paths)
- **Windows drives:** C:\, D:\, etc. shown as top-level shortcuts
- **Pinned folders:** Persisted to JSON. Drag to reorder. Right-click to unpin.
- **Color tag counts:** Show per-color file count badges
- **Custom emoji icons:** Emoji picker popup, persisted to JSON

Config dir:
- Windows: `%APPDATA%/dux-file-explorer/`
- Linux: `~/.config/dux-file-explorer/`

Files: `settings.json`, `folders.json`, `color-labels.json`, `folder-icons.json` (same schema as Swift app).

### Phase 4 — Actions Pane + Context Menu

**Actions pane (right side):**
- File/folder info header (icon, name, size, modified date)
- "Open with" section — discover apps that handle the file type
- Quick actions: Show in native file manager, Copy path, Rename
- Folder size calculation (async, cached)

**Context menu:**
Custom implementation (not native OS menu) matching the Swift version. Keyboard navigable.
Items: Open, Show in Explorer/Files, Copy path, Rename, Duplicate, Color label, New folder, Move to trash.

**Toast notifications:**
Bottom-center overlay, auto-dismiss after 2 seconds.

### Phase 5 — Basic Previews

Start with the simplest, most useful preview types:

| Type | Implementation |
|------|---------------|
| Text | Read file contents in Go, render in `<pre>` with syntax highlighting (highlight.js or Prism) |
| Image | `<img>` tag with file:// URL or base64 from Go backend |
| File info | Show metadata when no preview available |

Skip for v1: PDF, audio, video, archives, comics, EPUB, DMG, movies/OMDB, Makefile, package.json.

### Phase 6 — File Operations

All executed in Go backend:
- **Rename:** Go `os.Rename`
- **Delete/Trash:** Windows: use shell API for recycle bin; Linux: freedesktop trash spec or `gio trash`
- **New folder:** `os.MkdirAll`
- **Duplicate:** Copy file/dir with " copy" suffix, dedup name
- **Copy/Move from selection:** Batch copy or move files

### Phase 7 — Search

- Windows: Use `where` or bundled search tool
- Linux: Use `find` or `fd` if available
- Debounced input (200ms), results displayed in file list area
- Match the Swift behavior: dirs first, then files, sorted alphabetically

### Phase 8 — Selection System

Global selection that persists across folders:
- Space to add/remove files from selection
- Green highlight for files in selection
- Selection bar appears with count and actions (copy here, move here, clear)
- Ctrl+Shift+C to copy, Ctrl+Shift+V to move to current directory

## Platform Considerations

### Windows
- Path separator: `\` (Go handles this with `filepath` package)
- Drive letters: enumerate with `GetLogicalDrives` Win32 API
- Hidden files: check file attributes (not dot-prefix)
- Trash: Shell API `SHFileOperation` or `IFileOperation` for recycle bin
- Default apps: registry-based, use `shell32.dll` for "Open with"
- Config dir: `%APPDATA%/dux-file-explorer/`

### Linux
- Hidden files: dot-prefix convention
- Trash: freedesktop.org trash spec (`~/.local/share/Trash/`) or `gio trash`
- Default apps: `xdg-open`, `xdg-mime`
- Mounted volumes: parse `/proc/mounts` or `/etc/mtab`
- Config dir: `~/.config/dux-file-explorer/`

## Design Notes

### Layout
Match the Swift app's 3-pane layout exactly:
- Left sidebar: ~200px default, draggable divider
- Center file list: flexible, min ~400px
- Right pane: ~280px default, draggable divider
- Minimum window: 900x600

### Colors and Styles
- Background: `#faf9f5` (warm off-white) for sidebar, `#ffffff` for main area
- Selected row: `accent-color` at 18% opacity, do NOT invert text/icon colors
- Selection (global): green at 15% opacity
- Text sizes: match the Swift `.textStyle()` system — default 14px, small 12px, buttons 13px, title 15px semibold
- Icons: 22px in file rows, 26px in sidebar, 16-18px in context menu
- Folder icons: bundled Catppuccin SVGs from `app/Resources/Icons/`
- File icons: bundled vscode-icons SVGs, rendered as vectors for crispness

### Font
System font (Segoe UI on Windows, system sans on Linux). Monospace for code previews and shortcut keys.

## Out of Scope (v1)

- iPhone/iOS device browsing
- Movie info (OMDB integration)
- Comic book reader (CBZ/CBR)
- Archive browser (ZIP/RAR contents)
- DMG info
- PDF preview
- Audio/video player
- EPUB reader
- Image resize/convert tools
- App uninstaller
- Git repo detection
- npm package detection
- App updater
