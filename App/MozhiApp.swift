import SwiftUI
import AppIntents

@main
struct MozhiApp: App {
    init() {
        // 注册「墨指」在快捷指令里的建议短语（让 App 在快捷指令中更快出现）。
        Task {
            try? await MozhiAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
