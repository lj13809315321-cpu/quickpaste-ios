import SwiftUI
import AppIntents

@main
struct NianshuApp: App {
    init() {
        // 注册「粘鼠」在快捷指令里的建议短语（让 App 在快捷指令中更快出现）。
        Task {
            try? await NianshuAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
