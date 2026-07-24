# Code Structure - File Explorer Swift

## App Entry & Top-Level Layout

**Entry point:** `app/FileExplorerApp.swift`

- `@main struct FileExplorerApp: App` with `WindowGroup` containing `ContentView()` and a `Settings` scene with `SettingsView()`.
- `AppDelegate` handles `application(_:open:)` for files/folders opened from Finder/CLI. Posts `.openPathRequest` notification.
- CLI arguments: `args[1]` is resolved as initial path. If it is a file, the parent directory is opened and the file is selected.
- Static properties `FileExplorerApp.initialPath` and `FileExplorerApp.initialFile` carry the startup target into `FileExplorerManager.init()`.

**Window layout** (`ContentView.swift`):

```
ZStack (bottom-aligned) {
  VStack {
    Divider
    HStack {
      ShortcutsView (left sidebar)     -- width: settings.leftPaneWidth
      <draggable vertical divider>
      MainContentView                   -- minWidth: 600
    }
  }
  CustomContextMenuOverlay              -- floats above everything
  ToastView                             -- bottom notification
}
```

- `WindowAccessor` (NSViewRepresentable) saves/restores window frame via `AppSettings`.
- Minimum window: 900 x 600.

## Models

### FileSystemSource (`Models/Sources/FileSystemSource.swift`)
The **generic backend contract** every browsable source implements: path algebra (canonicalize/parent/breadcrumb), listing (async `list` plus sync escape hatches `listSyncIfCheap`/`existsSync` for the local no-flicker path), content transfer (`materialize`/`download`/`upload`), mutations (mkdir/createFile/move/delete/setHidden), and optional capabilities (`watch` change stream, `recursiveEntries` search walk).
`SourceCapabilities` gates UI actions per backend; `SourceRegistry` resolves the backend from the URL scheme (`file`, `iphone`, `ssh`; `smb`/`ftp` mount to `file://` and route to the local backend), so URLs are self-describing and history works across sources.

- **LocalFileSource** (`Models/Sources/LocalFileSource.swift`) -- FileManager enumeration (with `/bin/ls` and Finder Apple Events fallbacks for the TCC-protected `.Trash`), kqueue directory watching, recursive search walk, breadcrumb roots (home, /Volumes), and local mutation primitives.
- **iPhoneFileSource** (`Models/Sources/iPhoneFileSource.swift`) -- one instance per device over libimobiledevice. Virtual hierarchy: `iphone://<udid>/` lists file-sharing apps as folders (bundle id = path component, app name = displayName), deeper paths map to AFC `/Documents/...`. Context-explicit sync cores (list apps/dir, stat, download) are shared with iPhoneManager's transfer ops. Capabilities: write/rename/delete inside app Documents, read-only at the app level; `materialize` caches downloads keyed by size+mtime.
- **SSHFileSource** (`Models/Sources/SSHFileSource.swift`) -- SFTP browsing over libssh2 (`SSHConnection.swift` owns the socket/session/auth, known_hosts accept-new). `ssh://user@host/path` URLs; write/rename/delete but no recursive search or watch. `MountsManager` keeps SSH/SMB favorites and connects them.

### FileExplorerManager (`Models/FileExplorerManager.swift`)
The **central @MainActor ObservableObject**. Owns all navigation, file listing, search, and selection state for ALL backends -- the same pane, keyboard nav, and selection work on local, iPhone, and SSH sources.

**Key published state:**
- `currentPath: URL` -- current directory
- `directories: [CachedFileInfo]`, `files: [CachedFileInfo]` -- cached contents of current dir
- `allItems: [CachedFileInfo]` -- computed `directories + files`
- `selectedItem: URL?`, `selectedIndex: Int` -- single item cursor
- `sortMode: SortMode` (.type, .name, .modified, .size) -- triggers `loadContents()` on change; in Size mode local folder sizes are filled in asynchronously via `FolderSizeCache`
- `currentPane: MainPaneType` -- `.browser`, `.selection`, `.colorTag(TagColor)`
- `browserViewMode: BrowserViewMode` -- `.files`, `.selected`
- `showHidden`, `hiddenCount`, `hasImages`
- `isSearching`, `searchQuery`, `searchResults`, `isSearchRunning`, `listCursorIndex`
- `searchScannedCount`, `searchExtensionCounts`, `selectedSearchExtension` -- recursive search index/filter state
- `sidebarFocused`, `sidebarIndex`, `rightPaneFocused`, `rightPaneIndex`, `rightPaneItems`
- `renamingItem`, `renameText`, `showAppSelectorForURL`

**Key methods:**
- `loadContents()` -- lists the current directory through its `FileSystemSource` (sync fast path for cheap local listings, async otherwise), splits into dirs/files, sorts, detects images/hidden count
- `navigateTo(_ url)` -- resolves the backend by URL scheme, validates (or navigates optimistically for remote sources), pushes history, sets sort default for Downloads/Desktop, loads contents, restores selection memory
- `navigateUp()` -- remembers current folder in parent's selection memory, then navigates
- `goBack()` / `goForward()` -- history-based navigation
- `openItem(_ item)` -- directories: navigate; archives: extract; files: open with preferred app
- `startSearch()` -- begins a background recursive item scan, skipping heavy folders such as `.git`, `node_modules`, `tmp`, build/cache directories and listing matching folders and apps before files
- `performSearch(_ query)` -- filters the in-memory search index by name/path and selected extension, showing up to 1,000 results
- `selectNext()`, `selectPrevious()`, `jumpToLetter()`, `selectFirst()`, `selectLast()` -- keyboard nav
- `addFileToSelection()`, `toggleFileSelection()`, `selectAllFiles()` -- delegates to `SelectionManager.shared`

**Private state:**
- `history: [URL]`, `historyIndex: Int` -- back/forward navigation
- `selectionMemory: [String: URL]` -- remembers selected item per directory path

### FileExplorerManagerFileOps (extension, `Models/FileExplorerManagerFileOps.swift`)
File operation methods: `createNewFolder()`, `createNewFile()`, `duplicateFile()`, `addToZip()`, `extractArchive()`, `enableUnsafeApp()`, `moveToTrash()`, `refresh()`, `startRename()`, `cancelRename()`, `confirmRename()`, `toggleHidden()`.

### FileExplorerManagerSearch (extension, `Models/FileExplorerManagerSearch.swift`)
Search methods: `startSearch()`, `startSearch(withQuery:)`, `cancelSearch()`, `performSearch()`, `toggleSearchExtension()`, `rescanSearchIndexIfActive()`. Entry points are gated on the source's `.recursiveSearch` capability (remote backends get a toast instead of an empty pane). List cursor navigation: `listSelectNext()`, `listSelectPrevious()`, `listActivateItem()`.

### FileItem & SelectionManager (`Models/FileItem.swift`)
* `FileItem` is a unified file representation with `id`, `name`, `path`, `isDirectory`, `size`, `modifiedDate`, and a local, iPhone, or generic remote source.
* `SelectionManager` is a **singleton** managing a `Set<FileItem>`.
  It tracks `version: Int` for change detection.
  It supports add/remove/toggle/clear, move/copy/delete, and iPhone download/upload.

### CachedFileInfo (in FileExplorerManager.swift)
Lightweight struct: `url`, `isDirectory`, `size`, `modDate`, `isHidden`, `displayName`. Display model for directory listings.

### AppSettings (`Models/AppSettings.swift`)
**Singleton** persisting to `~/.config/dux-file-explorer/settings.json`. Debounced save (300ms). Key settings: font sizes, pane widths, window frame, `preferredApps`, `recentlyUsedApps`, `flatFolders`, `omdbAPIKey`.

### Other Singletons
All `@MainActor`:
- **ShortcutsManager** -- sidebar pinned folders (`~/.config/dux-file-explorer/folders.txt`)
- **ColorTagManager** -- 4-color label system (`color-labels.json`)
- **FolderIconManager** -- custom emoji folder icons (`folder-icons.json`)
- **IconProvider** -- bundled vscode-icons file SVGs and Catppuccin folder SVGs, cached
- **GitRepoManager** -- detects `.git`, parses remote URL for web links
- **NpmPackageManager** -- detects `package.json`, provides npm link
- **MovieManager** -- OMDB movie metadata + poster
- **VolumesManager** -- monitors mounted volumes via NSWorkspace notifications
- **iPhoneManager** -- iOS device detection/scanning; context-explicit AFC transfer ops used by SelectionManager and iPhoneFileSource (`iPhoneManagerFileOps.swift`). Browsing itself goes through iPhoneFileSource + the main browser pane
- **AppSearcher** -- finds apps that can open a file type
- **AppUninstaller** -- finds leftover app data for cleanup
- **FolderSizeCache** -- mtime-validated folder size cache (own queue); feeds real directory sizes to the Size sort mode
- **MountsManager** -- SSH/SMB favorites, connect dialog, server URL normalization
- **OperationManager** -- cancellable background operation runner with the running indicator
- **ToastManager** -- toast notification show/dismiss
- **ContextMenuManager** -- right-click menu state

## Views Hierarchy

```
ContentView
  +-- ShortcutsView (left sidebar)
  |     +-- ShortcutRow (Home, Desktop, Documents, Downloads, Applications)
  |     +-- ColorTagBoxes
  |     +-- iPhoneRow (per device)
  |     +-- DraggableShortcutRow (pinned folders, drag-reorder)
  |     +-- VolumeRow (mounted volumes) + FavoriteMountRow (disconnected favorites)
  |
  +-- <draggable vertical divider>
  |
  +-- MainContentView
        +-- MainPane (switches on currentPane)
        |     +-- .browser -> FileBrowserPane (local AND remote sources, e.g. iphone://, ssh://)
        |     |     +-- ActionButtonBar (hidden toggle, search, sort, new)
        |     |     +-- SearchBar + SearchResultsView (when isSearching)
        |     |     +-- FileTreeView (primary file listing)
        |     |
        |     +-- .colorTag(color) -> ColorTagView
        |
        +-- <draggable vertical divider>
        |
        +-- Right pane:
              +-- ActionsPane (actions capability-gated per source)
              +-- Preview area (when showPreviewPane):
                    MoviePreviewView / FolderGalleryPreview / PreviewPane
                    (remote files preview via materialize-to-cache, <= 20 MB)
```

## Navigation System

### Folder navigation
- **`navigateTo(_ url)`** -- validates path, saves selection memory, pushes history, sets `currentPath`, auto-selects sort mode (.modified for Downloads/Desktop, .name otherwise), calls `loadContents()`, restores selection.
- **`navigateUp()`** -- stores current dir URL in parent's selection memory, calls `navigateTo(parent)`.
- **`goBack()` / `goForward()`** -- moves `historyIndex` through history stack.

### Breadcrumbs
- **Tree mode** (`flatFolders == false`): `FileTreeView` computes `ancestors` array from current path up to home dir (or volume mount). Each is an `AncestorRow` (clickable, indented by depth).
- **Flat mode** (`flatFolders == true`): `FlatBreadcrumbRow` -- horizontal chevron-separated path. Toggle: `Cmd+T`.

### Sidebar navigation
- Tab cycles focus: main -> right pane -> sidebar -> main.
- Arrow keys navigate sidebar items, Enter activates.

## File Display

### FileTreeView (`Views/FileTreeView.swift`)
Primary file listing. Two modes via `settings.flatFolders`:
- **Tree**: ancestor rows (indented path) + children at `ancestors.count` depth. 20pt indent per level.
- **Flat**: `FlatBreadcrumbRow` + children at depth 1.

**FileTreeRow:** icon + filename + color dots + date + size. Single click on dir: select then navigate (150ms). Click file: toggle selection. Double click: open. Drag: `NSItemProvider`. Right-click: custom context menu. Background: blue=selected, green=in selection.

### Drop handling
Both views accept `.fileURL` drops -- copies files to current directory with name deduplication.

## Preview System

`PreviewType.detect(for:)` classifies by extension/filename:
- `.image`, `.pdf`, `.text`, `.json`, `.markdown`, `.fez`, `.audio`, `.video`, `.archive`, `.comic`, `.epub`, `.dmg`, `.makefile`, `.packageJson`, `.none`

Preview views in `Views/Preview/`: TextPreviewView, SyntaxHighlightView, HTMLPreviewView, JSONPreviewView, MarkdownPreviewView, ImagePreviewView, PDFPreviewView, AudioPreviewView, ArchivePreviewView, ComicPreviewView, EpubPreviewView, DMGPreviewView, MakefilePreviewView, PackageJsonPreviewView, MoviePreviewView, FolderGalleryPreview. (`.video` currently has no preview.)

## Key Patterns

### State management
- Singletons with `@MainActor` for all shared managers
- `FileExplorerManager` created as `@StateObject` in ContentView, passed down via `@ObservedObject`
- Change tracking via `.version` counters (ColorTagManager, SelectionManager)

### Keyboard shortcuts (KeyCaptureView in KeyboardHandler.swift)
`NSViewRepresentable` capturing all key events. Priority: context menu -> rename -> tab cycling -> sidebar -> right pane -> search -> normal mode. Normal mode: arrows (navigate/select), Space (toggle selection), Enter (rename), Backspace (go back), Cmd+Backspace (trash), letter (type-to-search; jump-to-letter on sources without search), Cmd+T (toggle tree/flat), Cmd+F (search), Ctrl+R (refresh).

### Context menu
Custom implementation via `ContextMenuManager` + `CustomContextMenuOverlay`. Not native macOS. Supports keyboard navigation.

### Text styles
`.textStyle(.default|.buttons|.small|.title)` modifier. Font sizes configurable in AppSettings.

## File Map

```
app/
  FileExplorerApp.swift              -- @main entry, AppDelegate (pins light appearance)
  ContentView.swift                  -- Root layout, WindowAccessor
  Models/
    Sources/
      FileSystemSource.swift         -- Backend contract, capabilities, SourceRegistry
      LocalFileSource.swift          -- Local disk backend (FileManager, kqueue watch)
      iPhoneFileSource.swift         -- iPhone backend (libimobiledevice, virtual app tree)
      SSHFileSource.swift            -- SFTP backend (ssh:// browsing)
      SSHConnection.swift            -- libssh2 socket/session/auth, sync SFTP ops
    FileExplorerManager.swift        -- Central state manager
    FileExplorerManagerFileOps.swift  -- File operations extension
    FileExplorerManagerSearch.swift   -- Search & list cursor extension
    FileItem.swift                   -- FileItem, SelectionManager, uniqueLocalDestination helper
    AppSettings.swift                -- Persisted settings singleton
    ShortcutsManager.swift           -- Sidebar built-ins + pinned folders
    ColorTagManager.swift            -- Color label system
    FolderIconManager.swift          -- Custom emoji folder icons
    IconProvider.swift               -- vscode-icons files and Catppuccin folders
    GitRepoManager.swift             -- Git repo detection
    NpmPackageManager.swift          -- npm package detection
    MountsManager.swift              -- SSH/SMB favorites and connection
    MovieManager.swift               -- OMDB movie info
    OperationManager.swift           -- Cancellable background operations
    ClipboardMonitor.swift           -- Clipboard link watcher (webloc drops)
    ArchiveDragSession.swift         -- AppKit drag source for multi-file drags
    VolumesManager.swift             -- Mounted volumes
    iPhoneManager.swift              -- iOS device detection/scanning
    iPhoneManagerFileOps.swift       -- Context-explicit iPhone transfer ops
    AppSearcher.swift                -- App discovery for "Open with"
    AppUninstaller.swift             -- App cleanup/uninstall
    FolderSizeCache.swift            -- Cached folder sizes (feeds Size sort)
    AppUpdater.swift                 -- GitHub release update checker
  Views/
    MainContentView.swift            -- Main layout, ActionButtonBar, dialogs
    KeyboardHandler.swift            -- KeyEventHandlingView, KeyCaptureView
    ShortcutsView.swift              -- Left sidebar
    ActionsPane.swift                -- Right pane actions (capability-gated)
    FileTreeView.swift               -- Tree/flat file listing (primary)
    FileRowMouseArea.swift           -- AppKit mouse handling for rows
    CustomContextMenu.swift          -- Right-click context menu system
    HelperViews.swift                -- FileDetailsView, EmptyFolderView, rename field
    SharedComponents.swift           -- Drop helpers, calculateFileSize, webloc writer
    TextStyles.swift                 -- .textStyle() modifier system
    ToastView.swift                  -- Toast notification, CopyProgressManager
    SettingsView.swift               -- Settings window
    ColorTagView.swift               -- Color tag file list
    EmojiPickerView.swift            -- Emoji picker for folder icons
    ExecuteScriptSheet.swift         -- Run script on selection
    FolderGalleryPreview.swift       -- Image grid preview
    MetadataSheet.swift              -- EXIF/metadata viewer
    ImageResizeSheet.swift           -- Image resize/crop
    ImageConvertSheet.swift          -- Image format conversion
    AppSelectorSheet.swift           -- App chooser dialog
    UninstallConfirmSheet.swift      -- App uninstall confirmation
    Panes/
      MainPane.swift                 -- Pane switcher
      FileBrowserPane.swift          -- File browser with search
    Preview/
      PreviewPane.swift              -- Preview type detection & dispatch
      TextPreviewView.swift          -- Plain text
      SyntaxHighlightView.swift      -- Syntax highlighting (bundled highlight.js)
      HTMLPreviewView.swift          -- Shared static-HTML webview
      JSONPreviewView.swift          -- JSON viewer
      MarkdownPreviewView.swift      -- Markdown renderer (bundled marked.js)
      FezPreviewView.swift           -- Fez template
      ImagePreviewView.swift         -- Image viewer
      PDFPreviewView.swift           -- PDF viewer
      AudioPreviewView.swift         -- Audio player
      ArchivePreviewView.swift       -- Archive contents
      ComicPreviewView.swift         -- Comic reader
      EpubPreviewView.swift          -- EPUB reader
      DMGPreviewView.swift           -- DMG info
      MakefilePreviewView.swift      -- Makefile targets
      PackageJsonPreviewView.swift   -- package.json info
      MoviePreviewView.swift         -- Movie info from OMDB
```
