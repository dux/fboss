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
- `previewStack`, `previewForwardStack: [PreviewTarget]` -- files reached by clicking links inside a preview; `previewURL` is what the right pane actually renders
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

The class body itself keeps only stored state, `init`/`deinit`, navigation/history, sidebar and right-pane cursors, directory monitoring, keyboard nav and the `SelectionManager` bridge.
Everything else lives in extension files next to it (Swift allows methods, computed properties and *static* stored properties in an extension -- only instance stored properties must stay in the class).

### FileExplorerManagerLoading (extension, `Models/FileExplorerManagerLoading.swift`)
The directory listing pipeline: `loadContents(completion:)` / `loadContents(selecting:)`, `applyLoadResult`, and the `nonisolated` pure helpers `buildListing` / `sortItems` that run the hidden-file policy, dir/file split and sort off the main actor.
Also the "Folder sizes for Size sort" block -- `refreshDirectorySizesIfSortingBySize()`, `applyDirectorySizes()`, `recursiveFolderSize()` -- which fills real recursive sizes in asynchronously via `FolderSizeCache` and re-sorts.
`loadGeneration` stays in the class body (stored) and is internal so this extension can bump/compare it to discard stale async loads.

### FileExplorerManagerOpen (extension, `Models/FileExplorerManagerOpen.swift`)
Opening items and archives: `cachedInfo(for:)`, `openItem()`, `openRemoteFile()`, `openFileWithPreferredApp()`, `extractArchive()`, `topLevelArchiveEntries()`, `decompressSingleFile()`.

### FileExplorerManagerFileOps (extension, `Models/FileExplorerManagerFileOps.swift`)
File operation methods: `createNewFolder()`, `createNewFile()`, `duplicateFile()`, `addToZip()`, `enableUnsafeApp()`, `moveToTrash()`, `refresh()`, `startRename()`, `cancelRename()`, `confirmRename()`, `toggleHidden()`.

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
- `.image`, `.pdf`, `.text`, `.json`, `.markdown`, `.fez`, `.audio`, `.video`, `.archive`, `.comic`, `.epub`, `.dmg`, `.pkg`, `.makefile`, `.hammerfile`, `.packageJson`, `.webloc`, `.none`

Preview views in `Views/Preview/`: TextPreviewView, SyntaxHighlightView, HTMLPreviewView, JSONPreviewView, MarkdownPreviewView, ImagePreviewView, PDFPreviewView, AudioPreviewView, ArchivePreviewView, ComicPreviewView, EpubPreviewView, DMGPreviewView, PkgPreviewView, MakefilePreviewView, HammerfilePreviewView, PackageJsonPreviewView, WeblocPreviewView, MoviePreviewView, FolderGalleryPreview. (`.video` currently has no preview.)

### Installer packages

`PkgPreviewView` covers `.pkg`, `.mpkg` and `.xip`, with the reading split out into `PkgInfoLoader` the same way `HammerTaskRunner` sits beside `HammerfilePreviewView`.
The view renders already-prepared values; every shell call and parser lives in the loader.

A flat `.pkg` is a xar archive, so `xar -t` lists its members in constant time and individual members can be extracted on their own.
The loader pulls out only `Distribution`, `PackageInfo` and `Bom` into a temp dir it deletes on the way out, and never touches `Payload` -- reading a 225 MB six-component package costs about 10 ms.
`pkgutil --payload-files` is deliberately unused: it silently reports only the first component of a multi-component package (371 of 5638 files on the .NET SDK) and exits 0 while doing it, so payload paths come from `lsbom -p fMs` over each component's Bom instead.

Three shapes of package all occur in the wild and the loader handles each: a distribution package with several components, a single-component flat package with no `Distribution` at all, and a payload-free package that installs by running scripts (no `Bom`, no `Payload`) which the pane reports rather than showing an empty file list.
A `pkg-ref`'s id is a component identifier and is not always the xar member name, so refs are keyed by the `#member` body of the ref.
`.mpkg` may be a directory bundle instead, read through `Contents/distribution.dist` and `Contents/Packages/`; a `.xip` keeps its payload in one compressed stream that cannot be listed without expanding it, so that pane shows identity and signature only.

Signing comes from `pkgutil --check-signature`, which needs care: it writes `Could not open package:` to stderr, exits 1 for a legitimately unsigned package, and omits the `Notarization:` line entirely for Apple-signed packages -- hence `PkgNotarization.notStated` as distinct from `.untrusted`.
Payloads reach 150k paths, so `PkgPayloadIndex` indexes entries by parent directory and the pane browses one directory at a time rather than laying out the whole listing.
Install hands off to Installer.app (Archive Utility for `.xip`) via LaunchServices; the app is unprivileged, so it never runs `installer` itself.

### Hammerfile task runner
The Hammerfile preview is interactive: `HammerTaskLoader` shells out to `hammer h:json` for the task list (namespaces included, hidden tasks dropped), falling back to a `task :name` / `desc '...'` scan of the file when hammer isn't installed. Clicking a task runs it through `HammerTaskRunner` in the Hammerfile's directory, streaming output into the pane.

`hammer` is a Ruby script in `~/bin`, which a GUI app's PATH doesn't have, so every invocation goes through `/bin/zsh -ilc` with the task passed positionally -- the same trick `runCodexApp` uses in SharedComponents. Output arrives via `readabilityHandler` and passes through `LineStreamDecoder`, which holds back partial lines so UTF-8 sequences split across chunks rejoin and ANSI escapes can be stripped from whole lines. One task runs at a time; switching files or closing the pane terminates it.

Note there is no JS bridge involved. `HTMLPreviewView` renders static pages only -- the sole HTML-to-app channels anywhere in the app are the plain-string `WKScriptMessageHandler` in MarkdownPreviewView and link interception in `decidePolicyFor`. Every interactive preview is native SwiftUI.

### Preview link following
Relative links inside a markdown preview open in the preview pane itself, leaving the browser panes untouched.
`MarkdownWebView` loads with the markdown file as its `baseURL`, so WebKit hands its navigation delegate already-absolute URLs; `MarkdownLinkTarget.resolve(_:)` classifies them as external / file / directory / missing (retrying after a trailing `:14` line suffix only when the literal path misses).

`FileExplorerManager` owns the resulting `previewStack` / `previewForwardStack` of `PreviewTarget` (url + optional heading anchor). The right pane renders `previewURL` (`previewStack.last ?? selectedItem`) and shows `PreviewFollowBar` while the stack is non-empty; the `.id()` on the preview subtree stays keyed on `selectedItem` so following a link updates the pane instead of rebuilding it. A `didSet` on `selectedItem` clears the stack whenever the cursor moves, which also covers `applyLoadResult` dropping the cursor on a watcher reload.

Following works for any previewable type, since the stack sits above `PreviewPane`'s type dispatch. Directory links are the one case that moves the browser (`navigateToFolder`). Remote previews pass `manager: nil` (hence `baseURL: nil`), disabling following, because a materialized cache copy has no siblings on disk. Same-document `#anchor` links are handled entirely in JS against generated GitHub-style heading slugs, and relative `<img>` sources are rewritten to `previewfile://` so they survive WebKit's subresource restrictions.

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
    FileExplorerManagerLoading.swift  -- Directory listing, sorting, folder sizes
    FileExplorerManagerOpen.swift     -- Open item, archive extract/decompress
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
      PreviewPane.swift              -- Preview type detection & dispatch, PreviewFollowBar
      MarkdownLinkTarget.swift       -- Resolves links clicked in a markdown preview
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
      PkgPreviewView.swift           -- Installer package info + payload browser
      PkgInfoLoader.swift            -- pkg/mpkg/xip metadata reading and parsers
      MakefilePreviewView.swift      -- Makefile targets
      HammerfilePreviewView.swift    -- Hammerfile task runner UI
      HammerTaskRunner.swift         -- hammer task discovery + streaming execution
      PackageJsonPreviewView.swift   -- package.json info
      MoviePreviewView.swift         -- Movie info from OMDB
```
