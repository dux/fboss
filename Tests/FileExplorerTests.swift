// URL literals in tests are compile-time known; a nil there is a test failure, which is the point.
// swiftlint:disable file_length force_unwrapping
import Testing
import Foundation
@testable import FileExplorer

// MARK: - IconProvider Tests

@Suite("IconProvider")
struct IconProviderTests {
    @Test("uses vscode-icons resource names for file extensions")
    @MainActor func fileExtensionResource() {
        let url = URL(fileURLWithPath: "/project/App.swift")
        #expect(IconProvider.resourceName(for: url, isDirectory: false) == "swift")
    }

    @Test("exact filenames take priority over their extensions")
    @MainActor func exactFilenameResource() {
        let url = URL(fileURLWithPath: "/project/package.json")
        #expect(IconProvider.resourceName(for: url, isDirectory: false) == "npm")
    }

    @Test("uses specialized directory resources")
    @MainActor func directoryResource() {
        let url = URL(fileURLWithPath: "/project/src")
        #expect(IconProvider.resourceName(for: url, isDirectory: true) == "folder_src")
    }

    @Test("keeps application bundle icons native")
    @MainActor func applicationResource() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        #expect(IconProvider.resourceName(for: url, isDirectory: true) == nil)
    }

    @Test("unknown items use bundled defaults")
    @MainActor func defaultResources() {
        let file = URL(fileURLWithPath: "/project/example.unknown-extension")
        let folder = URL(fileURLWithPath: "/project/unknown-folder")
        #expect(IconProvider.resourceName(for: file, isDirectory: false) == "_file")
        #expect(IconProvider.resourceName(for: folder, isDirectory: true) == "_folder")
    }
}

// MARK: - CachedFileInfo Tests

@Suite("CachedFileInfo")
struct CachedFileInfoTests {
    @Test("id is derived from URL")
    func idFromURL() {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let info = CachedFileInfo(url: url, isDirectory: false, size: 100, modDate: nil, isHidden: false)
        #expect(info.id == url.absoluteString)
    }

    @Test("name is last path component")
    func nameFromURL() {
        let info = CachedFileInfo(url: URL(fileURLWithPath: "/Users/test/Documents/file.txt"), isDirectory: false, size: 0, modDate: nil, isHidden: false)
        #expect(info.name == "file.txt")
    }

    @Test("allItems combines directories and files")
    @MainActor func allItemsCombined() {
        let manager = FileExplorerManager()
        let dir = CachedFileInfo(url: URL(fileURLWithPath: "/tmp/a"), isDirectory: true, size: 0, modDate: nil, isHidden: false)
        let file = CachedFileInfo(url: URL(fileURLWithPath: "/tmp/b.txt"), isDirectory: false, size: 10, modDate: nil, isHidden: false)
        manager.directories = [dir]
        manager.files = [file]
        #expect(manager.allItems.count == 2)
        #expect(manager.allItems[0].isDirectory == true)
        #expect(manager.allItems[1].isDirectory == false)
    }
}

// MARK: - Enum Tests

@Suite("Enums")
struct EnumTests {
    @Test("SortMode raw values")
    func sortModeRawValues() {
        #expect(SortMode.name.rawValue == "Name")
        #expect(SortMode.modified.rawValue == "Modified")
        #expect(SortMode.type.rawValue == "Type")
        #expect(SortMode.size.rawValue == "Size")
    }

    @Test("BrowserViewMode raw values")
    func browserViewModeRawValues() {
        #expect(BrowserViewMode.files.rawValue == "Files")
        #expect(BrowserViewMode.selected.rawValue == "Selected")
    }

    @Test("MainPaneType equality")
    func mainPaneTypeEquality() {
        let browser1 = MainPaneType.browser
        let browser2 = MainPaneType.browser
        #expect(browser1 == browser2)
        let tagRed1 = MainPaneType.colorTag(.red)
        let tagRed2 = MainPaneType.colorTag(.red)
        #expect(tagRed1 == tagRed2)
        #expect(tagRed1 != MainPaneType.colorTag(.blue))
        #expect(browser1 != MainPaneType.colorTag(.red))
    }

    @Test("TagColor has all four cases")
    func tagColorCases() {
        #expect(TagColor.allCases.count == 4)
        #expect(TagColor.allCases.contains(.red))
        #expect(TagColor.allCases.contains(.blue))
        #expect(TagColor.allCases.contains(.green))
        #expect(TagColor.allCases.contains(.orange))
    }

    @Test("TagColor labels are capitalized")
    func tagColorLabels() {
        #expect(TagColor.red.label == "Red")
        #expect(TagColor.blue.label == "Blue")
        #expect(TagColor.green.label == "Green")
        #expect(TagColor.orange.label == "Orange")
    }

    @Test("TagColor raw values")
    func tagColorRawValues() {
        #expect(TagColor.red.rawValue == "red")
        #expect(TagColor(rawValue: "blue") == .blue)
        #expect(TagColor(rawValue: "invalid") == nil)
    }
}

// MARK: - TaggedFile Tests

@Suite("TaggedFile")
struct TaggedFileTests {
    @Test("parentPath shortens home directory to tilde")
    func parentPathHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = TaggedFile(url: home.appendingPathComponent("test.txt"), exists: true, isDirectory: false)
        #expect(file.parentPath == "~")
    }

    @Test("parentPath shortens subdirectory of home")
    func parentPathSubdir() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = TaggedFile(url: home.appendingPathComponent("Documents/test.txt"), exists: true, isDirectory: false)
        #expect(file.parentPath == "~/Documents")
    }

    @Test("parentPath keeps absolute path for non-home")
    func parentPathAbsolute() {
        let file = TaggedFile(url: URL(fileURLWithPath: "/tmp/test.txt"), exists: true, isDirectory: false)
        #expect(file.parentPath == "/tmp")
    }

    @Test("name is last path component")
    func nameProperty() {
        let file = TaggedFile(url: URL(fileURLWithPath: "/tmp/myfile.pdf"), exists: true, isDirectory: false)
        #expect(file.name == "myfile.pdf")
    }

    @Test("id is path")
    func idProperty() {
        let file = TaggedFile(url: URL(fileURLWithPath: "/tmp/test.txt"), exists: true, isDirectory: false)
        #expect(file.id == "/tmp/test.txt")
    }
}

// MARK: - Test Helpers

func makeLocalItem(_ name: String, path: String) -> FileItem {
    FileItem(id: path, name: name, path: path, isDirectory: false, size: 0, modifiedDate: nil, source: .local)
}

func makeIPhoneItem(_ name: String, path: String) -> FileItem {
    FileItem(id: "iphone:dev1:app1:\(path)", name: name, path: path, isDirectory: false, size: 0, modifiedDate: nil, source: .iPhone(deviceId: "dev1", appId: "app1", appName: "App"))
}

// MARK: - FileItem Tests

@Suite("FileItem")
struct FileItemTests {
    @Test("fromLocal creates correct item")
    func fromLocal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let item = FileItem.fromLocal(home)
        #expect(item != nil)
        #expect(item?.name == home.lastPathComponent)
        if case .local = item?.source {} else {
            Issue.record("Expected .local source")
        }
    }

    @Test("items are equal by id")
    func equality() {
        let a = makeLocalItem("test.txt", path: "/tmp/test.txt")
        let b = makeLocalItem("test.txt", path: "/tmp/test.txt")
        #expect(a == b)
    }

    @Test("different paths are not equal")
    func inequality() {
        let a = makeLocalItem("a.txt", path: "/tmp/a.txt")
        let b = makeLocalItem("b.txt", path: "/tmp/b.txt")
        #expect(a != b)
    }

    @Test("localURL returns URL for local items")
    func localURL() {
        let item = makeLocalItem("f.txt", path: "/tmp/f.txt")
        #expect(item.localURL?.path == "/tmp/f.txt")
    }

    @Test("localURL returns nil for iPhone items")
    func localURLNilForIPhone() {
        let item = makeIPhoneItem("f.txt", path: "/Documents/f.txt")
        #expect(item.localURL == nil)
    }

    @Test("displayPath shortens home directory")
    func displayPathLocal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let item = makeLocalItem("test.txt", path: "\(home)/Documents/test.txt")
        #expect(item.displayPath == "~/Documents/test.txt")
    }

    @Test("displayPath shows iPhone prefix")
    func displayPathIPhone() {
        let item = makeIPhoneItem("f.txt", path: "/Documents/f.txt")
        #expect(item.displayPath == "iPhone: App/Documents/f.txt")
    }

    @Test("remote folder preserves its URL and directory metadata")
    @MainActor func remoteFolder() throws {
        let url = try #require(URL(string: "ssh://user@example.com/var/log"))
        let info = CachedFileInfo(
            url: url,
            isDirectory: true,
            size: 0,
            modDate: nil,
            isHidden: false
        )
        let item = FileItem.from(info: info)

        #expect(item?.remoteURL == url)
        #expect(item?.isDirectory == true)
        #expect(item?.id == url.absoluteString)
    }

    @Test("remote file preserves its URL and file metadata")
    @MainActor func remoteFile() throws {
        let url = try #require(URL(string: "ssh://user@example.com/var/log/app.log"))
        let modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let info = CachedFileInfo(
            url: url,
            isDirectory: false,
            size: 512,
            modDate: modifiedDate,
            isHidden: false
        )
        let item = FileItem.from(info: info)

        #expect(item?.remoteURL == url)
        #expect(item?.isDirectory == false)
        #expect(item?.size == 512)
        #expect(item?.modifiedDate == modifiedDate)
        #expect(item?.id == url.absoluteString)
    }
}

// MARK: - SelectionManager Tests

@Suite("SelectionManager")
struct SelectionManagerTests {
    @Test("add and remove items")
    @MainActor func addRemove() {
        let sel = SelectionManager.shared
        sel.clear()
        let item = makeLocalItem("test.txt", path: "/tmp/test-sel.txt")
        sel.add(item)
        #expect(sel.count == 1)
        #expect(sel.contains(item))
        sel.remove(item)
        #expect(sel.isEmpty)
        #expect(!sel.contains(item))
    }

    @Test("clear removes all items")
    @MainActor func clearAll() {
        let sel = SelectionManager.shared
        sel.clear()
        sel.add(makeLocalItem("a", path: "/tmp/a"))
        sel.add(makeLocalItem("b", path: "/tmp/b"))
        #expect(sel.count == 2)
        sel.clear()
        #expect(sel.isEmpty)
    }

    @Test("toggle adds then removes")
    @MainActor func toggle() {
        let sel = SelectionManager.shared
        sel.clear()
        let item = makeLocalItem("t", path: "/tmp/toggle-test")
        sel.toggle(item)
        #expect(sel.contains(item))
        sel.toggle(item)
        #expect(!sel.contains(item))
    }

    @Test("duplicate add does not increase count")
    @MainActor func duplicateAdd() {
        let sel = SelectionManager.shared
        sel.clear()
        let item = makeLocalItem("dup", path: "/tmp/dup-test")
        sel.add(item)
        sel.add(item)
        #expect(sel.count == 1)
    }

    @Test("localItems filters correctly")
    @MainActor func localItemsFilter() {
        let sel = SelectionManager.shared
        sel.clear()
        sel.add(makeLocalItem("local", path: "/tmp/local"))
        sel.add(makeIPhoneItem("phone", path: "/phone/file"))
        #expect(sel.localItems.count == 1)
        #expect(sel.iPhoneItems.count == 1)
        sel.clear()
    }

    @Test("removeByPath removes matching item")
    @MainActor func removeByPath() {
        let sel = SelectionManager.shared
        sel.clear()
        sel.add(makeLocalItem("x", path: "/tmp/x"))
        sel.removeByPath("/tmp/x")
        #expect(sel.isEmpty)
    }

    @Test("manager toggles listed remote files and folders in global selection")
    @MainActor func toggleListedRemoteItems() throws {
        let sel = SelectionManager.shared
        sel.clear()
        defer { sel.clear() }

        let manager = FileExplorerManager()
        let folderURL = try #require(URL(string: "ssh://user@example.com/var/log"))
        let fileURL = try #require(URL(string: "ssh://user@example.com/var/log/app.log"))
        manager.directories = [CachedFileInfo(
            url: folderURL,
            isDirectory: true,
            size: 0,
            modDate: nil,
            isHidden: false
        )]
        manager.files = [CachedFileInfo(
            url: fileURL,
            isDirectory: false,
            size: 512,
            modDate: nil,
            isHidden: false
        )]

        manager.toggleFileSelection(folderURL)
        manager.toggleFileSelection(fileURL)

        #expect(manager.isInSelection(folderURL))
        #expect(manager.isInSelection(fileURL))
        #expect(sel.remoteItems.count == 2)

        manager.toggleFileSelection(fileURL)

        #expect(manager.isInSelection(folderURL))
        #expect(!manager.isInSelection(fileURL))
    }

    @Test("Space selection toggles the current remote folder")
    @MainActor func toggleCurrentRemoteFolder() throws {
        let sel = SelectionManager.shared
        sel.clear()
        defer { sel.clear() }

        let manager = FileExplorerManager()
        let url = try #require(URL(string: "ssh://user@example.com/var/log"))
        manager.currentPath = url
        manager.selectedItem = url

        manager.toggleGlobalSelection()
        #expect(manager.isInSelection(url))

        manager.toggleGlobalSelection()
        #expect(!manager.isInSelection(url))
    }

    @Test("removing a local path preserves a remote item with the same path")
    @MainActor func removeLocalPathPreservesRemoteItem() throws {
        let sel = SelectionManager.shared
        sel.clear()
        defer { sel.clear() }

        let path = "/tmp/shared-name"
        let remoteURL = try #require(URL(string: "ssh://user@example.com\(path)"))
        let remoteItem = FileItem.fromRemote(CachedFileInfo(
            url: remoteURL,
            isDirectory: false,
            size: 0,
            modDate: nil,
            isHidden: false
        ))
        _ = sel.addItems([
            makeLocalItem("shared-name", path: path),
            remoteItem
        ])

        sel.removeByPath(path)

        #expect(!sel.containsLocal(URL(fileURLWithPath: path)))
        #expect(sel.containsRemote(remoteURL))
    }
}

// MARK: - FileExplorerManager Navigation Tests

@Suite("FileExplorerManager Navigation")
struct NavigationTests {
    @Test("navigateTo changes currentPath")
    @MainActor func navigateToDirectory() {
        let manager = FileExplorerManager()
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        manager.navigateTo(target)
        #expect(manager.currentPath.path == target.standardizedFileURL.path)
    }

    @Test("navigateUp goes to parent")
    @MainActor func navigateUp() {
        let manager = FileExplorerManager()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let target = home.appendingPathComponent("Desktop")
        manager.navigateTo(target)
        manager.navigateUp()
        #expect(manager.currentPath.path == home.standardizedFileURL.path)
    }

    @Test("clearSelection resets selected state")
    @MainActor func clearSelection() {
        let manager = FileExplorerManager()
        manager.selectedIndex = 5
        manager.selectedItem = URL(fileURLWithPath: "/tmp/test")
        manager.clearSelection()
        #expect(manager.selectedIndex == -1)
        #expect(manager.selectedItem == nil)
    }

    @Test("selectCurrentFolder selects the current path")
    @MainActor func selectCurrentFolder() {
        let manager = FileExplorerManager()
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        manager.navigateTo(target)
        manager.selectCurrentFolder()
        #expect(manager.selectedIndex == -1)
        #expect(manager.selectedItem == manager.currentPath)
    }

    @Test("sidebar focus and unfocus")
    @MainActor func sidebarFocus() {
        let manager = FileExplorerManager()
        #expect(!manager.sidebarFocused)
        manager.focusSidebar()
        #expect(manager.sidebarFocused)
        manager.unfocusSidebar()
        #expect(!manager.sidebarFocused)
    }

    @Test("right pane focus and unfocus")
    @MainActor func rightPaneFocus() {
        let manager = FileExplorerManager()
        #expect(!manager.rightPaneFocused)
        manager.focusRightPane()
        #expect(manager.rightPaneFocused)
        #expect(manager.rightPaneIndex == 0)
        manager.unfocusRightPane()
        #expect(!manager.rightPaneFocused)
    }
}

// MARK: - ToastManager Tests

@Suite("ToastManager")
struct ToastManagerTests {
    @Test("show sets message and isShowing")
    @MainActor func showMessage() {
        let toast = ToastManager.shared
        toast.show("Test message")
        #expect(toast.message == "Test message")
        #expect(toast.isShowing)
        #expect(toast.style == .info)
    }

    @Test("showError sets error style")
    @MainActor func showError() {
        let toast = ToastManager.shared
        toast.showError("Error occurred")
        #expect(toast.message == "Error occurred")
        #expect(toast.isShowing)
        #expect(toast.style == .error)
    }
}

// MARK: - FolderSizeCache Tests

@Suite("FolderSizeCache")
struct FolderSizeCacheTests {
    @Test("cache returns nil for unknown path")
    func unknownPath() {
        let cache = FolderSizeCache.shared
        let fake = URL(fileURLWithPath: "/tmp/nonexistent-folder-\(UUID().uuidString)")
        #expect(cache.getCachedSize(for: fake) == nil)
    }

    @Test("set and get cached size for existing directory")
    func setAndGet() {
        let cache = FolderSizeCache.shared
        // Use a unique temp dir so no stale cache entries interfere
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        cache.setCachedSize(for: testDir, size: 12345)
        // Give the async barrier write time to complete
        Thread.sleep(forTimeInterval: 0.15)
        let size = cache.getCachedSize(for: testDir)
        #expect(size == 12345)
    }

    @Test("invalidate removes cached entry")
    func invalidate() {
        let cache = FolderSizeCache.shared
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-inv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        cache.setCachedSize(for: testDir, size: 999)
        Thread.sleep(forTimeInterval: 0.15)
        cache.invalidate(for: testDir)
        Thread.sleep(forTimeInterval: 0.15)
        let size = cache.getCachedSize(for: testDir)
        #expect(size == nil)
    }
}

// MARK: - AppUninstaller Tests

@Suite("AppUninstaller")
struct AppUninstallerTests {
    @Test("returns empty for nonexistent app")
    func nonexistentApp() {
        let paths = AppUninstaller.findAppData(for: URL(fileURLWithPath: "/tmp/FakeApp-\(UUID().uuidString).app"))
        #expect(paths.isEmpty)
    }

    @Test("finds data for real app with known bundle ID")
    func realApp() {
        // Safari is always installed and has data
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let paths = AppUninstaller.findAppData(for: safari)
        // Safari should have at least some data dirs (Caches, Preferences, etc.)
        #expect(!paths.isEmpty)
    }
}

// MARK: - Helper Function Tests

@Suite("Helpers")
struct HelperTests {
    @Test("formatPath shortens home to tilde")
    func formatPathHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(formatPath(home, full: true) == "~")
    }

    @Test("formatPath shortens subdirectory")
    func formatPathSubdir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Documents"
        #expect(formatPath(path, full: true) == "~/Documents")
    }

    @Test("formatPath returns last component when not full")
    func formatPathShort() {
        #expect(formatPath("/Users/test/Documents", full: false) == "Documents")
    }

    @Test("formatPath keeps absolute for non-home paths")
    func formatPathAbsolute() {
        #expect(formatPath("/tmp/test", full: true) == "/tmp/test")
    }
}

// MARK: - SuppressSortDidSet Tests

@Suite("NavigateTo SortMode")
struct NavigateToSortModeTests {
    @Test("navigating to Downloads sets sortMode to modified")
    @MainActor func downloadsUsesModifiedSort() {
        let manager = FileExplorerManager()
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        manager.navigateTo(downloads)
        #expect(manager.sortMode == .modified)
    }

    @Test("navigating to Documents keeps sortMode as name")
    @MainActor func documentsUsesNameSort() {
        let manager = FileExplorerManager()
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        manager.navigateTo(docs)
        #expect(manager.sortMode == .name)
    }

    @Test("navigating from Downloads to Documents changes sortMode back to name")
    @MainActor func sortModeChangesOnNavigation() {
        let manager = FileExplorerManager()
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        manager.navigateTo(downloads)
        #expect(manager.sortMode == .modified)
        manager.navigateTo(docs)
        #expect(manager.sortMode == .name)
    }
}

// MARK: - UniqueDestination Tests

@Suite("UniqueDestination")
struct UniqueDestinationTests {
    @Test("numbered name is chosen when the original conflicts")
    func numberedOnConflict() throws {
        let fm = FileManager.default
        let destDir = fm.temporaryDirectory.appendingPathComponent("unique-dest-\(UUID().uuidString)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destDir) }

        try "existing".write(to: destDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let dest = uniqueLocalDestination(in: destDir) { numberedName("file.txt", attempt: $0) }
        #expect(dest.lastPathComponent == "file 2.txt")
    }

    @Test("original name is used when there is no conflict")
    func originalNameNoConflict() throws {
        let fm = FileManager.default
        let destDir = fm.temporaryDirectory.appendingPathComponent("unique-dest-nc-\(UUID().uuidString)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destDir) }

        let dest = uniqueLocalDestination(in: destDir) { numberedName("noconflict.txt", attempt: $0) }
        #expect(dest.lastPathComponent == "noconflict.txt")
    }

    @Test("multiple conflicts increment the number")
    func multipleConflicts() throws {
        let fm = FileManager.default
        let destDir = fm.temporaryDirectory.appendingPathComponent("unique-dest-mc-\(UUID().uuidString)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destDir) }

        try "v1".write(to: destDir.appendingPathComponent("doc.pdf"), atomically: true, encoding: .utf8)
        try "v2".write(to: destDir.appendingPathComponent("doc 2.pdf"), atomically: true, encoding: .utf8)

        let dest = uniqueLocalDestination(in: destDir) { numberedName("doc.pdf", attempt: $0) }
        #expect(dest.lastPathComponent == "doc 3.pdf")
    }

    @Test("extension-less names get a plain number suffix")
    func extensionlessName() {
        #expect(numberedName("folder", attempt: 0) == "folder")
        #expect(numberedName("folder", attempt: 1) == "folder 2")
        #expect(numberedName("archive.tar", attempt: 3) == "archive 4.tar")
    }
}

// MARK: - ShortcutItem Stable ID Tests

@Suite("ShortcutItem")
struct ShortcutItemTests {
    @Test("id is derived from URL path")
    func idFromPath() {
        let item = ShortcutItem(url: URL(fileURLWithPath: "/Users/test/Desktop"), name: "Desktop", isBuiltIn: true)
        #expect(item.id == "/Users/test/Desktop")
    }

    @Test("same URL produces same id")
    func stableId() {
        let url = URL(fileURLWithPath: "/Applications")
        let a = ShortcutItem(url: url, name: "Apps", isBuiltIn: true)
        let b = ShortcutItem(url: url, name: "Applications", isBuiltIn: false)
        #expect(a.id == b.id)
    }

    @Test("different URLs produce different ids")
    func differentIds() {
        let a = ShortcutItem(url: URL(fileURLWithPath: "/tmp/a"), name: "A", isBuiltIn: false)
        let b = ShortcutItem(url: URL(fileURLWithPath: "/tmp/b"), name: "B", isBuiltIn: false)
        #expect(a.id != b.id)
    }
}

// MARK: - ContainsLocal Tests

@Suite("SelectionManager ContainsLocal")
struct ContainsLocalTests {
    @Test("containsLocal returns true for added local URL")
    @MainActor func containsLocalTrue() {
        let sel = SelectionManager.shared
        sel.clear()
        let item = makeLocalItem("test.txt", path: "/tmp/contains-local-test")
        sel.add(item)
        #expect(sel.containsLocal(URL(fileURLWithPath: "/tmp/contains-local-test")))
        sel.clear()
    }

    @Test("containsLocal returns false for non-existent URL")
    @MainActor func containsLocalFalse() {
        let sel = SelectionManager.shared
        sel.clear()
        #expect(!sel.containsLocal(URL(fileURLWithPath: "/tmp/not-added")))
    }

    @Test("containsLocal returns false for iPhone items with same path")
    @MainActor func containsLocalNotIPhone() {
        let sel = SelectionManager.shared
        sel.clear()
        let item = makeIPhoneItem("phone.txt", path: "/tmp/phone-path")
        sel.add(item)
        #expect(!sel.containsLocal(URL(fileURLWithPath: "/tmp/phone-path")))
        sel.clear()
    }
}

// MARK: - ColorTagManager Tests

@Suite("ColorTagManager")
struct ColorTagManagerTests {
    @MainActor private func makeTempManager() -> (ColorTagManager, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("color-tag-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let jsonPath = tmpDir.appendingPathComponent("color-labels.json")
        let mgr = ColorTagManager(filePath: jsonPath)
        return (mgr, tmpDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("add and count are consistent")
    @MainActor func addAndCount() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url1 = URL(fileURLWithPath: "/tmp/file1.txt")
        let url2 = URL(fileURLWithPath: "/tmp/file2.txt")

        mgr.add(url1, color: .red)
        mgr.add(url2, color: .red)

        #expect(mgr.count(for: .red) == 2)
        #expect(mgr.list(.red).count == 2)
    }

    @Test("count matches list count always")
    @MainActor func countMatchesList() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/test-\($0).txt") }
        for url in urls {
            mgr.add(url, color: .blue)
        }

        #expect(mgr.count(for: .blue) == mgr.list(.blue).count)
        #expect(mgr.count(for: .blue) == 5)

        mgr.remove(urls[0], color: .blue)
        #expect(mgr.count(for: .blue) == mgr.list(.blue).count)
        #expect(mgr.count(for: .blue) == 4)

        mgr.remove(urls[1], color: .blue)
        mgr.remove(urls[2], color: .blue)
        #expect(mgr.count(for: .blue) == mgr.list(.blue).count)
        #expect(mgr.count(for: .blue) == 2)
    }

    @Test("duplicate add does not increase count")
    @MainActor func duplicateAdd() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url = URL(fileURLWithPath: "/tmp/dup.txt")
        mgr.add(url, color: .green)
        mgr.add(url, color: .green)
        mgr.add(url, color: .green)

        #expect(mgr.count(for: .green) == 1)
        #expect(mgr.list(.green).count == 1)
    }

    @Test("remove reduces count")
    @MainActor func removeReducesCount() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url = URL(fileURLWithPath: "/tmp/rm.txt")
        mgr.add(url, color: .orange)
        #expect(mgr.count(for: .orange) == 1)

        mgr.remove(url, color: .orange)
        #expect(mgr.count(for: .orange) == 0)
        #expect(mgr.list(.orange).isEmpty)
    }

    @Test("remove all colors")
    @MainActor func removeAllColors() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url = URL(fileURLWithPath: "/tmp/multi.txt")
        mgr.add(url, color: .red)
        mgr.add(url, color: .blue)
        mgr.add(url, color: .green)

        #expect(mgr.colorsForFile(url).count == 3)

        mgr.remove(url)
        for color in TagColor.allCases {
            #expect(mgr.count(for: color) == 0)
            #expect(mgr.list(color).isEmpty)
        }
    }

    @Test("toggle adds then removes")
    @MainActor func toggleAddRemove() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url = URL(fileURLWithPath: "/tmp/toggle.txt")
        mgr.toggle(url, color: .red)
        #expect(mgr.count(for: .red) == 1)
        #expect(mgr.isTagged(url, color: .red))

        mgr.toggle(url, color: .red)
        #expect(mgr.count(for: .red) == 0)
        #expect(!mgr.isTagged(url, color: .red))
    }

    @Test("totalCount is sum of all colors")
    @MainActor func totalCountSum() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        mgr.add(URL(fileURLWithPath: "/tmp/a"), color: .red)
        mgr.add(URL(fileURLWithPath: "/tmp/b"), color: .red)
        mgr.add(URL(fileURLWithPath: "/tmp/c"), color: .blue)

        #expect(mgr.totalCount == 3)
    }

    @Test("save and reload preserves data")
    @MainActor func saveAndReload() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("color-tag-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jsonPath = tmpDir.appendingPathComponent("color-labels.json")

        // Create, add, save
        let mgr1 = ColorTagManager(filePath: jsonPath)
        mgr1.add(URL(fileURLWithPath: "/tmp/persist1.txt"), color: .red)
        mgr1.add(URL(fileURLWithPath: "/tmp/persist2.txt"), color: .blue)
        mgr1.save()

        // Create new instance from same file
        let mgr2 = ColorTagManager(filePath: jsonPath)
        #expect(mgr2.count(for: .red) == 1)
        #expect(mgr2.count(for: .blue) == 1)
        #expect(mgr2.list(.red).count == 1)
        #expect(mgr2.list(.blue).count == 1)
    }

    @Test("colorsForFile returns correct colors")
    @MainActor func colorsForFile() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let url = URL(fileURLWithPath: "/tmp/multi-color.txt")
        mgr.add(url, color: .red)
        mgr.add(url, color: .orange)

        let colors = mgr.colorsForFile(url)
        #expect(colors.contains(.red))
        #expect(colors.contains(.orange))
        #expect(!colors.contains(.blue))
        #expect(!colors.contains(.green))
    }

    @Test("version increments on every mutation")
    @MainActor func versionIncrements() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let v0 = mgr.version
        mgr.add(URL(fileURLWithPath: "/tmp/v1"), color: .red)
        #expect(mgr.version == v0 + 1)

        mgr.remove(URL(fileURLWithPath: "/tmp/v1"), color: .red)
        #expect(mgr.version == v0 + 2)
    }
}

@Suite("Size Sort")
struct SizeSortTests {
    @Test("files sort largest first with name tie-breaker")
    @MainActor func filesSortBySize() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("size-sort-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        try Data(repeating: 0, count: 20).write(to: directory.appendingPathComponent("small.txt"))
        try Data(repeating: 0, count: 100).write(to: directory.appendingPathComponent("large-z.txt"))
        try Data(repeating: 0, count: 100).write(to: directory.appendingPathComponent("large-a.txt"))

        let manager = FileExplorerManager()
        manager.navigateTo(directory)
        // sortMode didSet reloads; small local dirs list synchronously
        manager.sortMode = .size

        #expect(manager.files.map(\.name) == ["large-a.txt", "large-z.txt", "small.txt"])
    }
}

// MARK: - AppSettings Tests

@Suite("AppSettings")
struct AppSettingsTests {
    @Test("shared instance has valid defaults or loaded values")
    @MainActor func sharedExists() {
        let settings = AppSettings.shared
        // Font size should be reasonable (either default 12 or loaded value)
        #expect(settings.previewFontSize >= 8)
        #expect(settings.previewFontSize <= 32)
    }

    @Test("font size clamped by increase/decrease")
    @MainActor func fontSizeClamping() {
        let settings = AppSettings.shared
        let original = settings.previewFontSize

        // Set to max and try to go higher
        settings.previewFontSize = 32
        settings.increaseFontSize()
        #expect(settings.previewFontSize == 32)

        // Set to min and try to go lower
        settings.previewFontSize = 8
        settings.decreaseFontSize()
        #expect(settings.previewFontSize == 8)

        // Restore original
        settings.previewFontSize = original
    }

    @Test("preferred apps add and remove")
    @MainActor func preferredApps() {
        let settings = AppSettings.shared
        let testKey = "__test_ext_\(UUID().uuidString)__"

        settings.addPreferredApp(for: testKey, appPath: "/Applications/TextEdit.app")
        #expect(settings.getPreferredApps(for: testKey).contains("/Applications/TextEdit.app"))

        settings.removePreferredApp(for: testKey, appPath: "/Applications/TextEdit.app")
        #expect(!settings.getPreferredApps(for: testKey).contains("/Applications/TextEdit.app"))
    }

    @Test("normalizes empty extension to __empty__")
    @MainActor func emptyExtensionNormalized() {
        let settings = AppSettings.shared
        settings.addPreferredApp(for: "", appPath: "/tmp/test.app")
        #expect(settings.getPreferredApps(for: "").contains("/tmp/test.app"))
        settings.removePreferredApp(for: "", appPath: "/tmp/test.app")
    }
}

// MARK: - MovieManager Tests

@Suite("MovieManager Detection")
struct MovieDetectionTests {
    @Test("detects year in parentheses")
    func parenthesesYear() {
        let result = MovieManager.detectMovie(folderName: "The Matrix (1999)")
        #expect(result != nil)
        #expect(result?.title == "The Matrix")
        #expect(result?.year == "1999")
    }

    @Test("detects dot-separated title and year")
    func dotSeparated() {
        let result = MovieManager.detectMovie(folderName: "Inception.2010.1080p.BluRay")
        #expect(result != nil)
        #expect(result?.title == "Inception")
        #expect(result?.year == "2010")
    }

    @Test("detects space-separated title and year")
    func spaceSeparated() {
        let result = MovieManager.detectMovie(folderName: "Blade Runner 2049 2017")
        #expect(result != nil)
        // "2049" is picked up as year first (it's in valid range)
        #expect(result?.title == "Blade Runner")
        #expect(result?.year == "2049")
    }

    @Test("detects title with year in parentheses even when title has numbers")
    func titleWithNumbers() {
        // Parenthesized year takes priority
        let result = MovieManager.detectMovie(folderName: "Blade Runner 2049 (2017)")
        #expect(result != nil)
        #expect(result?.title == "Blade Runner 2049")
        #expect(result?.year == "2017")
    }

    @Test("detects underscore-separated title")
    func underscoreSeparated() {
        let result = MovieManager.detectMovie(folderName: "The_Dark_Knight_2008")
        #expect(result != nil)
        #expect(result?.title == "The Dark Knight")
        #expect(result?.year == "2008")
    }

    @Test("returns nil for folder without year")
    func noYear() {
        let result = MovieManager.detectMovie(folderName: "Documents")
        #expect(result == nil)
    }

    @Test("returns nil for year outside range")
    func yearOutOfRange() {
        let result = MovieManager.detectMovie(folderName: "Project 1850")
        #expect(result == nil)
    }

    @Test("ignores a 4-digit token followed by a letter")
    func ignoresResolutionTag() {
        // "2000p" is a resolution-like tag, not a year
        let result = MovieManager.detectMovie(folderName: "Some Movie 2000p")
        #expect(result == nil)
    }

    @Test("picks the real year over a resolution-like token")
    func skipsResolutionTagKeepsYear() {
        // "2000p" must not be read as the year; the actual year wins
        let result = MovieManager.detectMovie(folderName: "Some Movie 2000p 2015")
        #expect(result?.year == "2015")
    }

    @Test("detects a leading year with the title after it")
    func yearFirst() {
        let result = MovieManager.detectMovie(folderName: "2000 The Movie")
        #expect(result?.title == "The Movie")
        #expect(result?.year == "2000")
    }

    @Test("ignores a 5-digit number")
    func ignoresLongerNumber() {
        let result = MovieManager.detectMovie(folderName: "Catalog 20000")
        #expect(result == nil)
    }

    @Test("strips multiple release tags after a leading year")
    func stripsMultipleTagsYearFirst() {
        // Year-first name whose title carries several release tags; used to crash
        // when cleanTitle sliced a truncated string with a stale index.
        let result = MovieManager.detectMovie(folderName: "2013 Searching for Sugar Man 1080p BluRay x264")
        #expect(result?.title == "Searching for Sugar Man")
        #expect(result?.year == "2013")
    }

    @Test("strips release tags from title")
    func stripsReleaseTags() {
        let result = MovieManager.detectMovie(folderName: "Interstellar.2014.1080p.BluRay.x264")
        #expect(result != nil)
        #expect(result?.title == "Interstellar")
    }

    @Test("handles hyphen-separated names")
    func hyphenSeparated() {
        let result = MovieManager.detectMovie(folderName: "No-Country-for-Old-Men-2007")
        #expect(result != nil)
        #expect(result?.title == "No Country for Old Men")
        #expect(result?.year == "2007")
    }

    @Test("extracts title from video filename with extension")
    func videoFilename() {
        let result = MovieManager.detectMovie(folderName: "Cabeza.de.Vaca.1991.DVDRip.blablebliblobluao.avi")
        #expect(result != nil)
        #expect(result?.title == "Cabeza de Vaca")
        #expect(result?.year == "1991")
    }

    @Test("extracts title from mkv filename")
    func mkvFilename() {
        let result = MovieManager.detectMovie(folderName: "The.Shawshank.Redemption.1994.1080p.BluRay.x264.mkv")
        #expect(result != nil)
        #expect(result?.title == "The Shawshank Redemption")
        #expect(result?.year == "1994")
    }

    @Test("OMDB URL keeps title and year as separate query items")
    func omdbURLIncludesYear() throws {
        let url = try #require(MovieManager.omdbURL(title: "Blade Runner 2049", year: "2017", apiKey: "test-key"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        #expect(items.first(where: { $0.name == "t" })?.value == "Blade Runner 2049")
        #expect(items.first(where: { $0.name == "y" })?.value == "2017")
        #expect(items.first(where: { $0.name == "plot" })?.value == "short")
        #expect(items.first(where: { $0.name == "apikey" })?.value == "test-key")
    }

    @Test("hasVideoFile detects video in folder")
    func hasVideoFile() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("video-check-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // No video yet
        #expect(!MovieManager.hasVideoFile(in: tmpDir))

        // Add a video file
        try "".write(to: tmpDir.appendingPathComponent("movie.mkv"), atomically: true, encoding: .utf8)
        #expect(MovieManager.hasVideoFile(in: tmpDir))
    }

    @Test("hasVideoFile ignores audio files")
    func ignoresAudio() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("audio-check-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("soundtrack.mp3"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("audio.flac"), atomically: true, encoding: .utf8)
        #expect(!MovieManager.hasVideoFile(in: tmpDir))
    }
}

// Live OMDB integration tests; opt in with OMDB_LIVE=1 so the default
// `swift test` run (a `hammer build` gate) never needs network.
@Suite("MovieManager API", .enabled(if: ProcessInfo.processInfo.environment["OMDB_LIVE"] == "1"))
struct MovieAPITests {
    @Test("fetches The Matrix folder and caches as imdb.txt")
    @MainActor func fetchMatrixFolder() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("movie-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let movieDir = tmpDir.appendingPathComponent("The Matrix (1999)")
        try fm.createDirectory(at: movieDir, withIntermediateDirectories: true)

        let info = await MovieManager.shared.getMovieInfo(for: movieDir)
        #expect(info != nil)
        #expect(info?.title == "The Matrix")
        #expect(info?.year == "1999")
        #expect(info?.imdbID == "tt0133093")
        #expect(info?.director.contains("Wachowski") == true)
        #expect(info?.imdbRating != "N/A")
        #expect(info?.topActors.count == 3)

        // Folder cache: imdb.txt inside the folder
        let cacheFile = movieDir.appendingPathComponent("imdb.txt")
        #expect(fm.fileExists(atPath: cacheFile.path))
        let text = try String(contentsOf: cacheFile, encoding: .utf8)
        let cached = try #require(MovieManager.parseIMDBText(text))
        #expect(cached.title == "The Matrix")
        #expect(text.hasPrefix("link: https://www.imdb.com/title/tt0133093/"))
        #expect(text.contains("\ndirector: Lana Wachowski"))
        #expect(text.contains("\nimdb_rating: "))

        print("=== imdb.txt for folder ===")
        print(text)
        print("=== end ===")

        // Second call should use cache
        let cached2 = await MovieManager.shared.getMovieInfo(for: movieDir)
        #expect(cached2?.title == "The Matrix")
    }

    @Test("fetches movie file and caches as imdb.txt")
    @MainActor func fetchMovieFile() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("movie-file-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let movieFile = tmpDir.appendingPathComponent("Inception.2010.1080p.BluRay.mkv")
        try "".write(to: movieFile, atomically: true, encoding: .utf8)

        let info = await MovieManager.shared.getMovieInfo(for: movieFile)
        #expect(info != nil)
        #expect(info?.title == "Inception")

        // File cache: imdb.txt in same dir
        let cacheFile = tmpDir.appendingPathComponent("imdb.txt")
        #expect(fm.fileExists(atPath: cacheFile.path))
        let text = try String(contentsOf: cacheFile, encoding: .utf8)
        let cached = try #require(MovieManager.parseIMDBText(text))
        #expect(cached.title == "Inception")
        #expect(text.hasPrefix("link: https://www.imdb.com/title/tt1375666/"))

        print("=== imdb.txt for file ===")
        print(text)
        print("=== end ===")
    }
}

// MARK: - Search Debounce Tests

@Suite("Search Debounce")
struct SearchDebounceTests {
    @Test("empty search clears results")
    @MainActor func emptySearchClears() {
        let manager = FileExplorerManager()
        manager.performSearch("")
        #expect(manager.searchResults.isEmpty)
        #expect(!manager.isSearchRunning)
    }

    @Test("whitespace-only search clears results")
    @MainActor func whitespaceSearchClears() {
        let manager = FileExplorerManager()
        manager.performSearch("   ")
        #expect(manager.searchResults.isEmpty)
        #expect(!manager.isSearchRunning)
    }

    @Test("active empty search shows indexed files")
    @MainActor func activeEmptySearchShowsIndexedFiles() {
        let manager = FileExplorerManager()
        let root = URL(fileURLWithPath: "/tmp/search-index")
        let psd = CachedFileInfo(
            url: root.appendingPathComponent("design.psd"),
            isDirectory: false,
            size: 1,
            modDate: nil,
            isHidden: false
        )
        let jpg = CachedFileInfo(
            url: root.appendingPathComponent("preview.jpg"),
            isDirectory: false,
            size: 1,
            modDate: nil,
            isHidden: false
        )

        manager.currentPath = root
        manager.isSearching = true
        manager.searchAllItems = [psd, jpg]
        manager.searchScannedCount = 2
        manager.searchExtensionCounts = ["psd": 1, "jpg": 1]
        manager.performSearch("")

        #expect(manager.searchResults.map(\.name) == ["design.psd", "preview.jpg"])
        #expect(!manager.isSearchRunning)
    }

    @Test("extension toggle filters indexed search results")
    @MainActor func extensionToggleFiltersIndexedResults() {
        let manager = FileExplorerManager()
        let root = URL(fileURLWithPath: "/tmp/search-index")
        let psd = CachedFileInfo(
            url: root.appendingPathComponent("art/design.psd"),
            isDirectory: false,
            size: 1,
            modDate: nil,
            isHidden: false
        )
        let jpg = CachedFileInfo(
            url: root.appendingPathComponent("art/design.jpg"),
            isDirectory: false,
            size: 1,
            modDate: nil,
            isHidden: false
        )

        manager.currentPath = root
        manager.isSearching = true
        manager.searchAllItems = [psd, jpg]
        manager.searchScannedCount = 2
        manager.searchExtensionCounts = ["psd": 1, "jpg": 1]
        manager.performSearch("design")
        manager.toggleSearchExtension("psd")

        #expect(manager.searchResults.map(\.name) == ["design.psd"])
        #expect(manager.selectedSearchExtension == "psd")

        manager.toggleSearchExtension("psd")
        #expect(manager.searchResults.map(\.name) == ["design.psd", "design.jpg"])
        #expect(manager.selectedSearchExtension == nil)
    }

    @Test("folders and apps are searchable and appear before files")
    @MainActor func foldersAndAppsAppearBeforeFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("search-items-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Matching Folder")
        let app = root.appendingPathComponent("Matching App.app")
        let file = root.appendingPathComponent("Matching File.txt")

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        try "match".write(to: file, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let manager = FileExplorerManager()
        manager.currentPath = root
        manager.startSearch(withQuery: "matching")

        for _ in 0..<200 {
            if !manager.isSearchRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!manager.isSearchRunning)
        let names = manager.searchResults.map(\.name)
        let folderIndex = try #require(names.firstIndex(of: folder.lastPathComponent))
        let appIndex = try #require(names.firstIndex(of: app.lastPathComponent))
        let fileIndex = try #require(names.firstIndex(of: file.lastPathComponent))
        #expect(folderIndex < fileIndex)
        #expect(appIndex < fileIndex)
    }
}

// MARK: - ShortcutsManager Pin/Unpin Tests

@Suite("ShortcutsManager Pin")
struct ShortcutsManagerPinTests {
    @MainActor private func makeTempManager() -> (ShortcutsManager, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcuts-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let mgr = ShortcutsManager(configDir: tmpDir)
        return (mgr, tmpDir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("addFolder pins a directory and it appears in customFolders")
    @MainActor func pinFolder() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-target-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        mgr.addFolder(folder)
        #expect(mgr.customFolders.contains(where: { $0.path == folder.path }))
    }

    @Test("pinned folder appears in allShortcuts as non-built-in")
    @MainActor func pinnedInAllShortcuts() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-shortcut-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        mgr.addFolder(folder)
        let match = mgr.allShortcuts.first(where: { $0.url.path == folder.path })
        #expect(match != nil)
        #expect(match?.isBuiltIn == false)
        #expect(match?.name == folder.lastPathComponent)
    }

    @Test("duplicate addFolder does not create duplicates")
    @MainActor func noDuplicatePin() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-pin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        mgr.addFolder(folder)
        mgr.addFolder(folder)
        let count = mgr.customFolders.filter { $0.path == folder.path }.count
        #expect(count == 1)
    }

    @Test("removeFolder unpins a directory")
    @MainActor func unpinFolder() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        mgr.addFolder(folder)
        #expect(mgr.customFolders.contains(where: { $0.path == folder.path }))

        mgr.removeFolder(folder)
        #expect(!mgr.customFolders.contains(where: { $0.path == folder.path }))
    }

    @Test("pinned folders persist to disk and reload")
    @MainActor func persistAndReload() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcuts-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-pin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Pin and save
        let mgr1 = ShortcutsManager(configDir: tmpDir)
        mgr1.addFolder(folder)

        // Reload from same config dir
        let mgr2 = ShortcutsManager(configDir: tmpDir)
        #expect(mgr2.customFolders.contains(where: { $0.path == folder.path }))
    }

    @Test("moveFolder reorders pinned folders")
    @MainActor func reorderFolders() {
        let (mgr, dir) = makeTempManager()
        defer { cleanup(dir) }

        let a = FileManager.default.temporaryDirectory.appendingPathComponent("order-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("order-b-\(UUID().uuidString)")
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("order-c-\(UUID().uuidString)")
        for f in [a, b, c] {
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        }
        defer { for f in [a, b, c] { try? FileManager.default.removeItem(at: f) } }

        mgr.addFolder(a)
        mgr.addFolder(b)
        mgr.addFolder(c)
        #expect(mgr.customFolders[0].path == a.path)

        // Move last to first
        mgr.moveFolder(from: IndexSet(integer: 2), to: 0)
        #expect(mgr.customFolders[0].path == c.path)
        #expect(mgr.customFolders[1].path == a.path)
        #expect(mgr.customFolders[2].path == b.path)
    }
}

// MARK: - Markdown Link Following Tests

@Suite("MarkdownLinkTarget")
struct MarkdownLinkTargetTests {
    /// Builds a throwaway tree: dir/, dir/sub/, dir/README.md, dir/sub/App.swift
    private func makeTree() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdlink-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("README.md").path, contents: Data())
        FileManager.default.createFile(atPath: sub.appendingPathComponent("App.swift").path, contents: Data())
        return root
    }

    @Test("resolves a file to a preview target")
    func resolvesFile() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = MarkdownLinkTarget.resolve(root.appendingPathComponent("README.md"))
        #expect(target == .file(PreviewTarget(root.appendingPathComponent("README.md"))))
    }

    @Test("resolves a directory separately from a file")
    func resolvesDirectory() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = MarkdownLinkTarget.resolve(root.appendingPathComponent("sub"))
        #expect(target == .directory(root.appendingPathComponent("sub")))
    }

    @Test("carries the anchor fragment alongside the file")
    func keepsFragment() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = URL(string: "file://\(root.path)/README.md#install")!
        guard case .file(let target) = MarkdownLinkTarget.resolve(url) else {
            Issue.record("expected a file target")
            return
        }
        #expect(target.fragment == "install")
        #expect(target.url.lastPathComponent == "README.md")
    }

    @Test("normalizes .. segments")
    func normalizesParentSegments() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("sub/../README.md")
        #expect(MarkdownLinkTarget.resolve(url) == .file(PreviewTarget(root.appendingPathComponent("README.md"))))
    }

    @Test("handles percent-encoded spaces in names")
    func decodesPercentEncoding() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("my notes.md").path, contents: Data())

        let url = URL(string: "file://\(root.path)/my%20notes.md")!
        #expect(MarkdownLinkTarget.resolve(url) == .file(PreviewTarget(root.appendingPathComponent("my notes.md"))))
    }

    @Test("strips editor-style line and column suffixes")
    func stripsLineSuffix() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let swiftFile = root.appendingPathComponent("sub/App.swift")

        #expect(MarkdownLinkTarget.resolve(root.appendingPathComponent("sub/App.swift:14")) == .file(PreviewTarget(swiftFile)))
        #expect(MarkdownLinkTarget.resolve(root.appendingPathComponent("sub/App.swift:14:3")) == .file(PreviewTarget(swiftFile)))
    }

    @Test("a real file whose name ends in a colon suffix wins over stripping")
    func literalPathBeatsStripping() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.md:14").path, contents: Data())

        let url = root.appendingPathComponent("notes.md:14")
        #expect(MarkdownLinkTarget.resolve(url) == .file(PreviewTarget(url)))
    }

    @Test("web and mail links are external")
    func externalSchemes() {
        #expect(MarkdownLinkTarget.resolve(URL(string: "https://example.com")!) == .external(URL(string: "https://example.com")!))
        #expect(MarkdownLinkTarget.resolve(URL(string: "mailto:a@b.c")!) == .external(URL(string: "mailto:a@b.c")!))
    }

    @Test("a path that is not on disk reports missing")
    func missingPath() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("nope.md")
        #expect(MarkdownLinkTarget.resolve(url) == .missing(url.path))
    }
}

@Suite("Preview follow stack")
struct PreviewFollowStackTests {
    @Test("following pushes onto the stack without touching the cursor")
    @MainActor func followKeepsCursor() {
        let mgr = FileExplorerManager()
        let readme = URL(fileURLWithPath: "/tmp/README.md")
        let other = URL(fileURLWithPath: "/tmp/OTHER.md")
        mgr.selectedItem = readme

        mgr.followPreview(PreviewTarget(other))

        #expect(mgr.selectedItem == readme)
        #expect(mgr.previewURL == other)
        #expect(mgr.isFollowingPreview)
    }

    @Test("back walks the chain and forward re-enters it")
    @MainActor func backAndForward() {
        let mgr = FileExplorerManager()
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        mgr.selectedItem = URL(fileURLWithPath: "/tmp/root.md")

        mgr.followPreview(PreviewTarget(a))
        mgr.followPreview(PreviewTarget(b))
        #expect(mgr.previewURL == b)

        #expect(mgr.previewBack())
        #expect(mgr.previewURL == a)
        #expect(mgr.previewBack())
        #expect(mgr.previewURL == mgr.selectedItem)

        mgr.previewGoForward()
        #expect(mgr.previewURL == a)
    }

    @Test("back reports false when nothing has been followed")
    @MainActor func backOnEmptyStack() {
        let mgr = FileExplorerManager()
        #expect(mgr.previewBack() == false)
    }

    @Test("following a new link drops the forward stack")
    @MainActor func followClearsForward() {
        let mgr = FileExplorerManager()
        mgr.followPreview(PreviewTarget(URL(fileURLWithPath: "/tmp/a.md")))
        mgr.previewBack()
        #expect(!mgr.previewForwardStack.isEmpty)

        mgr.followPreview(PreviewTarget(URL(fileURLWithPath: "/tmp/c.md")))
        #expect(mgr.previewForwardStack.isEmpty)
    }

    @Test("moving the browser cursor ends the excursion")
    @MainActor func cursorChangeClearsStack() {
        let mgr = FileExplorerManager()
        mgr.selectedItem = URL(fileURLWithPath: "/tmp/root.md")
        mgr.followPreview(PreviewTarget(URL(fileURLWithPath: "/tmp/a.md")))
        mgr.previewBack()

        mgr.selectedItem = URL(fileURLWithPath: "/tmp/elsewhere.md")

        #expect(mgr.previewStack.isEmpty)
        #expect(mgr.previewForwardStack.isEmpty)
        #expect(mgr.previewURL == mgr.selectedItem)
    }

    @Test("the cursor being dropped on a reload also ends it")
    @MainActor func nilCursorClearsStack() {
        let mgr = FileExplorerManager()
        mgr.selectedItem = URL(fileURLWithPath: "/tmp/root.md")
        mgr.followPreview(PreviewTarget(URL(fileURLWithPath: "/tmp/a.md")))

        mgr.selectedItem = nil

        #expect(!mgr.isFollowingPreview)
        #expect(mgr.previewURL == nil)
    }
}

// MARK: - Hammerfile Tests

@Suite("Hammerfile tasks")
struct HammerTaskTests {
    @Test("Hammerfile gets the runner preview, whatever the casing")
    func detectsHammerfile() {
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/project/Hammerfile")) == .hammerfile)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/project/hammerfile")) == .hammerfile)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/project/Makefile")) == .makefile)
    }

    /// Trimmed shape of real `hammer h:json` output, banner line included -- a chatty shell
    /// profile can print before hammer does, so the decoder has to skip to the first brace.
    private static let sampleJSON = """
    > hammer h:json
    {
      "schema": 1,
      "hammer_version": "0.3.22",
      "commands": {
        "h": {
          "h:version": {"name": "h:version", "path": "h:version", "desc": "Print version", "brief": "Print version", "hidden": false}
        },
        "__root": {
          "build": {"name": "build", "path": "build", "desc": "Lint, test, build", "brief": "Lint, test, build", "hidden": false},
          "clean": {"name": "clean", "path": "clean", "desc": "Remove build artifacts\\nsecond line", "brief": null, "hidden": false},
          "secret": {"name": "secret", "path": "secret", "desc": "Internal", "brief": "Internal", "hidden": true}
        }
      }
    }
    """

    @Test("decodes h:json, root tasks first, hidden ones dropped")
    func decodesCLIDefinition() throws {
        let data = Data(Self.sampleJSON.utf8)
        let start = try #require(data.firstIndex(of: UInt8(ascii: "{")))
        let groups = try #require(HammerTaskLoader.decode(Data(data[start...])))

        #expect(groups.count == 2)
        #expect(groups[0].namespace.isEmpty)
        #expect(groups[1].namespace == "h")

        #expect(groups[0].tasks.map(\.name) == ["build", "clean"])
        #expect(groups[0].tasks[0].desc == "Lint, test, build")
        // Multi-line descriptions are cut to what fits one row.
        #expect(groups[0].tasks[1].desc == "Remove build artifacts")
        #expect(groups[1].tasks[0].path == "h:version")
    }

    @Test("falls back to parsing the file when the CLI is unavailable")
    func parsesSource() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Hammerfile")
        try """
        APP_NAME ||= 'Demo'

        task :lint do
          desc 'Run SwiftLint'
          proc { sh 'swiftlint' }
        end

        task :build do
          desc "Build the app"
          proc { sh 'swift build' }
        end

        task :bare do
          proc { sh 'true' }
        end
        """.write(to: file, atomically: true, encoding: .utf8)

        let groups = HammerTaskLoader.parseSource(file)
        let tasks = try #require(groups.first).tasks

        #expect(tasks.map(\.name) == ["lint", "build", "bare"])
        #expect(tasks[0].desc == "Run SwiftLint")
        #expect(tasks[1].desc == "Build the app")
        #expect(tasks[2].desc.isEmpty)
    }
}

@Suite("Hammer runner")
struct HammerRunnerTests {
    /// The same login-shell lookup the runner does, so this suite skips itself on machines
    /// that don't have hammer installed.
    static func loginShellHasHammer() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `+m` matches makeHammerProcess: without it this interactive shell stops in
        // tcsetpgrp (SIGTTOU) and `swift test` hangs here forever when run from a terminal.
        process.arguments = ["+m", "-ilc", "command -v hammer"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// An interactive shell with no tty complains on its way up; none of that belongs in the
    /// pane. Only a real run exercises the marker that separates start-up from task output.
    @Test("keeps shell start-up noise out of task output", .enabled(if: Self.loginShellHasHammer()))
    @MainActor func suppressesStartupNoise() async throws {
        let runner = HammerTaskRunner()
        let task = HammerTask(path: "h:version", name: "h:version", desc: "")
        runner.run(task, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        let deadline = Date().addingTimeInterval(60)
        while runner.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(!runner.isRunning)
        #expect(runner.exitCode == 0)
        #expect(!runner.output.isEmpty)
        #expect(!runner.output.contains("can't change option"))
        #expect(!runner.output.contains("__file_explorer_hammer_ready__"))
    }
}

@Suite("Hammer output decoding")
struct LineStreamDecoderTests {
    @Test("emits only whole lines, holding the partial one back")
    func buffersPartialLines() {
        let decoder = LineStreamDecoder()

        #expect(decoder.lines(from: Data("first\nsec".utf8)) == ["first"])
        #expect(decoder.lines(from: Data("ond\n".utf8)) == ["second"])
        #expect(decoder.drain(Data("no newline".utf8)) == ["no newline"])
    }

    @Test("a UTF-8 sequence split across chunks survives")
    func rejoinsSplitCharacters() {
        let decoder = LineStreamDecoder()
        let bytes = Array("café\n".utf8)   // "é" is two bytes

        // Cut between the two bytes of "é".
        #expect(decoder.lines(from: Data(bytes[0..<4])).isEmpty)
        #expect(decoder.lines(from: Data(bytes[4...])) == ["café"])
    }

    @Test("strips ANSI colours and honours carriage-return overwrites")
    func cleansTerminalControls() {
        let decoder = LineStreamDecoder()
        let line = "\u{1B}[36mbuilding\u{1B}[0m\n"

        #expect(decoder.lines(from: Data(line.utf8)) == ["building"])
        #expect(decoder.lines(from: Data("50%\r100%\n".utf8)) == ["100%"])
    }
}

// MARK: - Installer package tests

/// Every fixture here is real output captured from a package on disk, so the parsers
/// are tested against the shapes they actually meet rather than idealised ones.
@Suite("PkgInfoLoader")
struct PkgInfoLoaderTests {

    // MARK: pkgutil --check-signature

    @Test("reads authority and notarization from a Developer ID package")
    func parsesDeveloperIDSignature() {
        let output = """
        Package "dotnet-sdk--10.0.400.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-07-29 19:15:53 +0000
           Certificate Chain:
            1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)
               Expires: 2027-02-01 22:12:15 +0000
               SHA256 Fingerprint:
                   64 5D 86 D2 48
               ------------------------------------------------------------------------
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        let signature = PkgInfoLoader.parseSignature(output)

        #expect(signature.isSigned)
        #expect(signature.notarization == .trusted)
        #expect(signature.authority == "Developer ID Installer: Microsoft Corporation (UBF8T346G9)")
        #expect(signature.timestamp == "2026-07-29 19:15:53 +0000")
        #expect(!signature.unreadable)
    }

    @Test("an Apple-signed package has no notarization verdict at all")
    func parsesAppleSignature() {
        let output = """
        Package "MobileDevice.pkg":
           Status: signed Apple Software
           Certificate Chain:
            1. Software Update
               Expires: 2029-04-14 21:28:23 +0000
        """
        let signature = PkgInfoLoader.parseSignature(output)

        #expect(signature.isSigned)
        // Absent line means "not applicable" - reporting false here would wrongly flag
        // every Apple system package as un-notarized.
        #expect(signature.notarization == .notStated)
        #expect(signature.authority == "Software Update")
    }

    @Test("an unsigned package is recognised, not treated as an error")
    func parsesUnsignedPackage() {
        let signature = PkgInfoLoader.parseSignature("""
        Package "Downloads":
           Status: no signature
        """)

        #expect(!signature.isSigned)
        #expect(!signature.unreadable)
        #expect(signature.authority == nil)
    }

    @Test("an unopenable file is flagged unreadable")
    func parsesUnreadablePackage() {
        let signature = PkgInfoLoader.parseSignature("Could not open package: /etc/hosts")

        #expect(signature.unreadable)
        #expect(!signature.isSigned)
    }

    // MARK: PackageInfo

    @Test("reads payload size and location from a component")
    func parsesComponentPackageInfo() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info overwrite-permissions="true" relocatable="false" \
        identifier="com.microsoft.dotnet.sharedhost.component.osx.arm64" version="10.0.11" \
        format-version="2" install-location="/usr/local/share/dotnet" auth="root">
            <payload numberOfFiles="4" installKBytes="216"/>
        </pkg-info>
        """
        let info = PkgInfoLoader.parsePackageInfo(xml)

        #expect(info?.identifier == "com.microsoft.dotnet.sharedhost.component.osx.arm64")
        #expect(info?.version == "10.0.11")
        #expect(info?.installLocation == "/usr/local/share/dotnet")
        #expect(info?.installKBytes == 216)
        #expect(info?.numberOfFiles == 4)
        #expect(info?.requiresRoot == true)
    }

    @Test("a script-only package reports no payload and keeps its install location")
    func parsesPayloadFreePackageInfo() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info overwrite-permissions="true" relocatable="false" identifier="com.gog.galaxy" \
        postinstall-action="none" version="0" format-version="2" \
        install-location="/Applications/" auth="root">
            <bundle-version/>
            <scripts><postinstall file="./postinstall"/></scripts>
        </pkg-info>
        """
        let info = PkgInfoLoader.parsePackageInfo(xml)

        #expect(info?.identifier == "com.gog.galaxy")
        #expect(info?.installKBytes == 0)
        #expect(info?.numberOfFiles == 0)
        // The trailing slash is real; it must not survive into the UI.
        #expect(info?.installLocation == "/Applications")
    }

    @Test("falls back to the volume-group location Apple components use")
    func parsesAppleComponentPackageInfo() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <pkg-info format-version="2" relocatable="true" identifier="com.apple.pkg.MobileDevice" \
        system-volume-group-install-location="/Library/Apple/" auth="root" version="4.0.0.0.1.1772003596">
          <payload installKBytes="36015" numberOfFiles="366"/>
        </pkg-info>
        """
        let info = PkgInfoLoader.parsePackageInfo(xml)

        #expect(info?.identifier == "com.apple.pkg.MobileDevice")
        #expect(info?.installLocation == "/Library/Apple")
        #expect(info?.installKBytes == 36015)
    }

    @Test("a missing install-location means the root")
    func defaultsInstallLocationToRoot() {
        #expect(PkgInfoLoader.normalizeLocation(nil) == "/")
        #expect(PkgInfoLoader.normalizeLocation("") == "/")
        #expect(PkgInfoLoader.normalizeLocation("/") == "/")
        #expect(PkgInfoLoader.normalizeLocation("Library/Apple/") == "/Library/Apple")
    }

    // MARK: Distribution

    @Test("keys refs by the archive member, which is not always the ref id")
    func parsesDistributionMemberMapping() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <pkg-ref id="com.gog.galaxy"><bundle-version/></pkg-ref>
            <title>GOG Galaxy</title>
            <options rootVolumeOnly="true"/>
            <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
            <choice id="com.gog.galaxy" visible="false"><pkg-ref id="com.gog.galaxy"/></choice>
            <pkg-ref id="com.gog.galaxy" version="0" installKBytes="0">#galaxyClientFirst.pkg</pkg-ref>
        </installer-gui-script>
        """
        let distribution = PkgInfoLoader.parseDistribution(xml)

        #expect(distribution?.title == "GOG Galaxy")
        #expect(distribution?.minOSVersion == "14.0")
        // The ref id is com.gog.galaxy but the xar member is galaxyClientFirst.pkg.
        #expect(distribution?.refs["galaxyClientFirst.pkg"]?.id == "com.gog.galaxy")
        #expect(distribution?.refs["com.gog.galaxy"] == nil)
    }

    @Test("collects per-component titles and sizes from a multi-component distribution")
    func parsesMultiComponentDistribution() {
        let xml = """
        <?xml version="1.0" standalone="yes"?>
        <installer-gui-script minSpecVersion="2">
            <title>Microsoft .NET SDK 10.0.400 (arm64)</title>
            <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
            <choice id="dev.pkg" visible="true" title="Microsoft .NET SDK 10.0.400 (arm64)">
                <pkg-ref id="dev.pkg"/>
            </choice>
            <choice id="host.pkg" visible="true" title="Microsoft .NET Host">
                <pkg-ref id="host.pkg"/>
            </choice>
            <pkg-ref id="dev.pkg" packageIdentifier="com.microsoft.dotnet.dev" \
        version="10.0.400" installKBytes="515998">#dev.pkg</pkg-ref>
            <pkg-ref id="host.pkg" packageIdentifier="com.microsoft.dotnet.sharedhost" \
        version="10.0.11" installKBytes="216">#host.pkg</pkg-ref>
        </installer-gui-script>
        """
        let distribution = PkgInfoLoader.parseDistribution(xml)

        #expect(distribution?.title == "Microsoft .NET SDK 10.0.400 (arm64)")
        #expect(distribution?.minOSVersion == "12.0")
        #expect(distribution?.refs.count == 2)
        #expect(distribution?.refs["dev.pkg"]?.installKBytes == 515998)
        #expect(distribution?.refs["dev.pkg"]?.packageIdentifier == "com.microsoft.dotnet.dev")
        #expect(distribution?.title(forMember: "host.pkg") == "Microsoft .NET Host")
    }

    // MARK: lsbom

    @Test("indexes payload paths by parent directory")
    func parsesLsbomIntoDirectoryIndex() {
        // `lsbom -p fMs`: path, symbolic mode, size - tab separated, size empty for dirs.
        let output = [
            ".\tdrwxr-xr-x \t",
            "./Applications\tdrwxr-xr-x \t",
            "./Applications/Foo.app\tdrwxr-xr-x \t",
            "./Applications/Foo.app/Contents\tdrwxr-xr-x \t",
            "./Applications/Foo.app/Contents/Info.plist\t-rw-r--r-- \t3291",
            "./LICENSE.txt\t-rw-r--r-- \t1116"
        ].joined(separator: "\n")

        let index = PkgInfoLoader.parseLsbom(output)

        // "." itself is the root marker, not an entry.
        #expect(index.totalPaths == 5)
        #expect(!index.truncated)

        let root = index.entries(at: ".")
        #expect(root.map(\.name) == ["Applications", "LICENSE.txt"])
        #expect(root.first?.isDirectory == true)
        #expect(root.last?.size == 1116)

        let contents = index.entries(at: "./Applications/Foo.app/Contents")
        #expect(contents.map(\.name) == ["Info.plist"])
        #expect(contents.first?.size == 3291)
    }

    @Test("directories sort ahead of files")
    func sortsPayloadDirectoriesFirst() {
        let output = [
            "./a.txt\t-rw-r--r-- \t10",
            "./zeta\tdrwxr-xr-x \t",
            "./b.txt\t-rw-r--r-- \t20"
        ].joined(separator: "\n")

        #expect(PkgInfoLoader.parseLsbom(output).entries(at: ".").map(\.name) == ["zeta", "a.txt", "b.txt"])
    }

    @Test("stops indexing at the limit and says so")
    func truncatesOversizePayloads() {
        let output = (0..<50).map { "./file\($0)\t-rw-r--r-- \t1" }.joined(separator: "\n")
        let index = PkgInfoLoader.parseLsbom(output, limit: 10)

        #expect(index.totalPaths == 10)
        #expect(index.truncated)
    }

    // MARK: Receipts

    @Test("reads an installed receipt plist")
    func parsesReceipt() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>install-location</key><string>Library/Caches</string>
            <key>install-time</key><integer>1787119432</integer>
            <key>pkg-version</key><string>26213.1006.5011</string>
            <key>pkgid</key><string>com.microsoft.teams2</string>
            <key>volume</key><string>/</string>
        </dict></plist>
        """
        let receipt = PkgInfoLoader.parseReceipt(Data(plist.utf8))

        #expect(receipt?.version == "26213.1006.5011")
        #expect(receipt?.installDate == Date(timeIntervalSince1970: 1787119432))
        #expect(receipt?.volume == "/")
    }

    @Test("no receipt output yields no receipt")
    func rejectsMissingReceipt() {
        #expect(PkgInfoLoader.parseReceipt(Data("No receipt for 'com.gog.galaxy' found at '/'.".utf8)) == nil)
    }
}

// MARK: - PreviewType Tests

@Suite("PreviewType")
struct PreviewTypeTests {
    @Test("installer packages get the package preview")
    func detectsInstallerPackages() {
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/Foo.pkg")) == .pkg)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/Foo.mpkg")) == .pkg)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/Xcode.xip")) == .pkg)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/FOO.PKG")) == .pkg)
    }

    @Test("neighbouring container formats keep their own previews")
    func doesNotStealOtherContainers() {
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/Foo.dmg")) == .dmg)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/Foo.zip")) == .archive)
        #expect(PreviewType.detect(for: URL(fileURLWithPath: "/tmp/package.json")) == .packageJson)
    }

}

// swiftlint:enable force_unwrapping
