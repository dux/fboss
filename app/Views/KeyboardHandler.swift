import SwiftUI
import AppKit

struct KeyEventHandlingView: NSViewRepresentable {
    @ObservedObject var manager: FileExplorerManager

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.manager = manager
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.manager = manager
        // Reclaim focus when no sheet/dialog is active and we don't have focus
        if manager.renamingItem == nil && manager.duplicatingItem == nil && !manager.isSearching && !manager.showNewFolderDialog && !manager.showNewFileDialog {
            if let window = nsView.window {
                let responder = window.firstResponder
                // Reclaim if focus is on the window itself (sheet just closed) or already on us
                if responder === window || responder === nsView || responder is KeyCaptureView {
                    if !(responder is KeyCaptureView) {
                        DispatchQueue.main.async {
                            window.makeFirstResponder(nsView)
                        }
                    }
                }
            }
        }
    }
}

class KeyCaptureView: NSView {
    var manager: FileExplorerManager?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let manager else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 && OperationManager.shared.cancelCurrent() {
            return
        }

        // Cmd+T: toggle tree/flat view from any focus mode
        if event.keyCode == 17 && event.modifierFlags.contains(.command) {
            AppSettings.shared.flatFolders.toggle()
            return
        }

        // Cmd+Shift+N: create new folder
        if event.keyCode == 45 && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
            if manager.currentPane == .browser {
                manager.promptForNewFolder()
            }
            return
        }

        // Cmd+Shift+F: create new file
        if event.keyCode == 3 && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
            if manager.currentPane == .browser {
                manager.promptForNewFile()
            }
            return
        }

        if handleContextMenuNavigation(event) { return }
        if handleRenameMode(event, manager: manager) { return }
        if handleTabCycle(event, manager: manager) { return }
        if handleSidebarMode(event, manager: manager) { return }
        if handleRightPaneMode(event, manager: manager) { return }
        if handleOpenWithPreferred(event, manager: manager) { return }
        if handleSearchNavigation(event, manager: manager) { return }
        if handleColorTagNavigation(event, manager: manager) { return }
        if handleNormalMode(event, manager: manager) { return }

        super.keyDown(with: event)
    }

    private func handleRenameMode(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard manager.renamingItem != nil else { return false }

        if event.keyCode == 53 {
            manager.cancelRename()
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self)
            }
        }
        return true
    }

    private func handleTabCycle(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard event.keyCode == 48 else { return false }

        if manager.sidebarFocused {
            manager.unfocusSidebar()
        } else if manager.rightPaneFocused {
            manager.unfocusRightPane()
            manager.focusSidebar()
        } else {
            manager.focusRightPane()
        }
        return true
    }

    private func handleSidebarMode(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard manager.sidebarFocused else { return false }

        switch event.keyCode {
        case 125:
            manager.sidebarSelectNext()
        case 126:
            manager.sidebarSelectPrevious()
        case 124, 36:
            manager.sidebarActivate()
        case 53:
            manager.unfocusSidebar()
        default:
            break
        }
        return true
    }

    private func handleRightPaneMode(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard manager.rightPaneFocused else { return false }

        switch event.keyCode {
        case 125:
            manager.rightPaneSelectNext()
        case 126:
            manager.rightPaneSelectPrevious()
        case 36:
            manager.rightPaneActivate()
        case 123, 53:
            manager.unfocusRightPane()
        default:
            break
        }
        return true
    }

    private func handleOpenWithPreferred(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard event.keyCode == 31 && event.modifierFlags.contains(.command) else { return false }

        if manager.isSearching {
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < manager.searchResults.count {
                let item = manager.searchResults[manager.listCursorIndex]
                manager.listActivateItem(url: item.url, isDirectory: item.isDirectory)
            }
            return true
        }

        if case .colorTag(let tagColor) = manager.currentPane {
            let files = ColorTagManager.shared.list(tagColor)
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < files.count {
                let file = files[manager.listCursorIndex]
                if file.exists {
                    manager.listActivateItem(url: file.url, isDirectory: file.isDirectory)
                }
            }
            return true
        }

        if let item = manager.selectedItem {
            let isDirectory = manager.cachedInfo(for: item)?.isDirectory
                ?? (SourceRegistry.shared.source(for: item).existsSync(item) == .directory)
            if isDirectory {
                manager.navigateTo(item)
            } else {
                manager.openFileWithPreferredApp(item)
            }
        }
        return true
    }

    private func handleSearchNavigation(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard manager.isSearching else { return false }

        switch event.keyCode {
        case 125:
            manager.listSelectNext(count: manager.searchResults.count)
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < manager.searchResults.count {
                let item = manager.searchResults[manager.listCursorIndex]
                manager.selectItem(at: -1, url: item.url)
            }
            return true
        case 126:
            manager.listSelectPrevious(count: manager.searchResults.count)
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < manager.searchResults.count {
                let item = manager.searchResults[manager.listCursorIndex]
                manager.selectItem(at: -1, url: item.url)
            }
            return true
        case 36:
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < manager.searchResults.count {
                let item = manager.searchResults[manager.listCursorIndex]
                manager.listActivateItem(url: item.url, isDirectory: item.isDirectory)
            }
            return true
        case 53:
            manager.cancelSearch()
            return true
        default:
            return false
        }
    }

    private func handleColorTagNavigation(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        guard case .colorTag(let tagColor) = manager.currentPane else { return false }

        let files = ColorTagManager.shared.list(tagColor)
        switch event.keyCode {
        case 125:
            manager.listSelectNext(count: files.count)
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < files.count {
                manager.selectItem(at: -1, url: files[manager.listCursorIndex].url)
            }
            return true
        case 126:
            manager.listSelectPrevious(count: files.count)
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < files.count {
                manager.selectItem(at: -1, url: files[manager.listCursorIndex].url)
            }
            return true
        case 36:
            if manager.listCursorIndex >= 0 && manager.listCursorIndex < files.count {
                let file = files[manager.listCursorIndex]
                if file.exists {
                    manager.listActivateItem(url: file.url, isDirectory: file.isDirectory)
                }
            }
            return true
        case 53:
            manager.currentPane = .browser
            manager.listCursorIndex = -1
            return true
        default:
            return false
        }
    }

    private func handleContextMenuNavigation(_ event: NSEvent) -> Bool {
        let contextMenu = ContextMenuManager.shared
        guard contextMenu.isShowing else { return false }
        switch event.keyCode {
        case 125: // Down
            contextMenu.moveFocus(1)
            return true
        case 126: // Up
            contextMenu.moveFocus(-1)
            return true
        case 36: // Enter
            contextMenu.activateFocused()
            return true
        case 53: // Escape
            contextMenu.dismiss()
            return true
        default:
            return false
        }
    }

    private func handleNormalMode(_ event: NSEvent, manager: FileExplorerManager) -> Bool {
        switch event.keyCode {
        case 0:
            if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
                manager.selectAllFiles()
                return true
            }
        case 8: // C key
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                let selection = SelectionManager.shared
                guard !selection.items.isEmpty else { return false }
                let items = selection.localItems.compactMap { item in
                    item.localURL.map { (name: item.name, url: $0) }
                }
                let dest = manager.currentPath
                selection.clear()
                Task {
                    let count = await CopyProgressManager.shared.copyItems(items, to: dest)
                    ToastManager.shared.show("Copied \(count) item(s)")
                    manager.refresh()
                }
                return true
            }
            if event.modifierFlags.contains(.control) {
                if let item = manager.selectedItem {
                    manager.toggleFileSelection(item)
                }
                return true
            }
        case 15:
            if event.modifierFlags.contains(.control) {
                manager.refresh()
                return true
            }
        case 125:
            if event.modifierFlags.contains(.command) {
                navigateIntoSelectedDirectoryIfNeeded(manager)
            } else {
                manager.selectNext()
            }
            return true
        case 126:
            if event.modifierFlags.contains(.command) {
                manager.navigateUp()
            } else {
                manager.selectPrevious()
            }
            return true
        case 123:
            manager.navigateUp()
            return true
        case 124:
            navigateIntoSelectedDirectoryIfNeeded(manager)
            return true
        case 49:
            manager.toggleGlobalSelection()
            return true
        case 36:
            if manager.selectedItem != nil {
                manager.startRename()
            }
            return true
        case 51: // Backspace
            if event.modifierFlags.contains(.command) {
                if let item = manager.selectedItem {
                    manager.moveToTrash(item)
                }
            } else {
                manager.goBack()
            }
            return true
        case 115:
            manager.selectFirst()
            return true
        case 119:
            manager.selectLast()
            return true
        case 53:
            // Step back out of a followed preview link before touching the selection
            if manager.previewBack() {
                return true
            }
            if manager.browserViewMode != .files {
                manager.browserViewMode = .files
            } else if manager.selectedItem != nil {
                manager.selectedItem = nil
                manager.selectedIndex = -1
            }
            return true
        case 47: // Period key - show context menu
            showContextMenuForSelected(manager)
            return true
        case 9: // V key - Cmd+Shift+V: move selection here
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                let selection = SelectionManager.shared
                guard !selection.items.isEmpty else { return false }
                let items = selection.localItems.compactMap { item in
                    item.localURL.map { (name: item.name, url: $0) }
                }
                let dest = manager.currentPath
                selection.clear()
                Task {
                    let count = await selection.moveItems(items, to: dest)
                    ToastManager.shared.show("Moved \(count) file(s)")
                    manager.refresh()
                }
                return true
            }
        case 46: // M key - Cmd+Shift+M: context menu
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                showContextMenuForSelected(manager)
                return true
            }
        case 2: // D key - Cmd+Shift+D: duplicate
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                let selection = SelectionManager.shared
                let locals = selection.items.filter { if case .local = $0.source { return true } else { return false } }
                guard locals.count == 1, let url = locals.first?.localURL else { return false }
                manager.promptDuplicate(url)
                selection.clear()
                return true
            }
        default:
            break
        }

        // Type-to-search lives after the switch so letters whose keyCode matched
        // a shortcut case above (a/c/d/m/r/v) still reach it when pressed bare.
        if let chars = event.characters, chars.count == 1,
           let c = chars.first, c.isLetter,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control) {
            if manager.canSearchCurrentSource {
                manager.startSearch(withQuery: String(c))
            } else {
                manager.jumpToLetter(c)
            }
            return true
        }

        return false
    }

    private func navigateIntoSelectedDirectoryIfNeeded(_ manager: FileExplorerManager) {
        guard let item = manager.selectedItem else { return }

        let isDirectory = manager.cachedInfo(for: item)?.isDirectory
            ?? (SourceRegistry.shared.source(for: item).existsSync(item) == .directory)
        guard isDirectory else { return }

        manager.navigateTo(item) {
            manager.restoreSelection()
            if manager.selectedItem == nil && !manager.allItems.isEmpty {
                manager.selectItem(at: 0, url: manager.allItems[0].url)
            }
        }
    }

    private func showContextMenuForSelected(_ manager: FileExplorerManager) {
        guard let item = manager.selectedItem else { return }
        // Position menu near center of the window
        let position: CGPoint
        if let window = self.window {
            let contentHeight = window.contentView?.frame.height ?? 400
            let contentWidth = window.contentView?.frame.width ?? 600
            position = CGPoint(x: contentWidth / 2, y: contentHeight / 2)
        } else {
            position = CGPoint(x: 300, y: 200)
        }
        Task { @MainActor in
            ContextMenuManager.shared.show(url: item, at: position, keyboardTriggered: true)
        }
    }
}
