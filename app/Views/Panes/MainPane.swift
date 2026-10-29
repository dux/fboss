import SwiftUI

struct MainPane: View {
    @ObservedObject var manager: FileExplorerManager

    private var appSelectorURL: URL {
        manager.showAppSelectorForURL ?? URL(fileURLWithPath: "/")
    }

    private var appSelectorFileType: String {
        guard let url = manager.showAppSelectorForURL else { return "__empty__" }
        return AppSettings.fileTypeKey(for: url, isDirectory: false)
    }

    var body: some View {
        Group {
            switch manager.currentPane {
            case .browser:
                FileBrowserPane(manager: manager)
            case .colorTag(let color):
                ColorTagView(color: color, manager: manager)
            }
        }
        .sheet(isPresented: Binding(
            get: { manager.showAppSelectorForURL != nil },
            set: { if !$0 { manager.showAppSelectorForURL = nil } }
        )) {
            AppSelectorSheet(
                targetURL: appSelectorURL,
                fileType: appSelectorFileType,
                settings: AppSettings.shared,
                isPresented: Binding(
                    get: { manager.showAppSelectorForURL != nil },
                    set: { if !$0 { manager.showAppSelectorForURL = nil } }
                )
            )
        }
    }
}
