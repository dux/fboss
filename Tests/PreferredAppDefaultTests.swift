import Foundation
import Testing
@testable import FileExplorer

@Suite("Preferred app default")
struct PreferredAppDefaultTests {
    @Test("setDefaultPreferredApp inserts at the top, moves an existing entry up, and never duplicates")
    @MainActor func ordering() {
        let settings = makeTestSettings()
        settings.setDefaultPreferredApp(for: "MKV", appPath: "/Applications/IINA.app")
        #expect(settings.getPreferredApps(for: "mkv") == ["/Applications/IINA.app"])

        settings.addPreferredApp(for: "mkv", appPath: "/Applications/VLC.app")
        settings.setDefaultPreferredApp(for: "mkv", appPath: "/System/Applications/QuickTime Player.app")
        #expect(settings.getPreferredApps(for: "mkv") == ["/System/Applications/QuickTime Player.app", "/Applications/IINA.app", "/Applications/VLC.app"])

        settings.setDefaultPreferredApp(for: "mkv", appPath: "/Applications/VLC.app")
        settings.setDefaultPreferredApp(for: "mkv", appPath: "/Applications/VLC.app")
        #expect(settings.getPreferredApps(for: "mkv") == ["/Applications/VLC.app", "/System/Applications/QuickTime Player.app", "/Applications/IINA.app"])
    }
}
