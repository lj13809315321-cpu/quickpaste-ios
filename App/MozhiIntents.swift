import AppIntents

// MARK: - 连续复制 · 快捷指令接入
//
// 让用户能在 iOS「快捷指令」App 里搜到「墨指」，并一键开关画中画连续复制；
// 也可被 Siri 语音唤起、放进「自动化」（如：连上家里 WiFi 自动开启）。
//
// 实现要点：
//  · 意图全部放在【主 App】(Mozhi target)，不走键盘扩展——键盘扩展里起不了画中画。
//  · 「开启 / 切换」会把 App 短暂拉到前台（openAppWhenRun），因为画中画必须
//    由前台 App 的窗口承载，和你在 App 内点开启是同一套逻辑。
//  · 复用既有 PiPManager.shared.start() / stop()，键盘与 App 内部状态会自动同步。
//  · 意图类不加 @MainActor（否则与快捷指令 Provider 实例化冲突），UI 调用用
//    MainActor.run 切到主线程。

/// 开启连续复制：拉起画中画小窗开始跨 App 抓取剪贴板。
final class StartContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "开启连续复制"
    static var description: LocalizedStringResource =
        "拉起墨指画中画小窗，开始跨 App 连续复制（会短暂切到墨指前台以启动画中画）。"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // 窗口就绪与画中画重试已内置于 PiPManager.start()，这里直接调即可。
        await MainActor.run { PiPManager.shared.start() }
        return .result()
    }
}

/// 关闭连续复制：关掉画中画小窗。用「就地停止」剪贴板指令实现，
/// 后台主 App 每 0.4 秒自行消费并停掉画中画 —— 无需切到前台、真生效。
final class StopContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭连续复制"
    static var description: LocalizedStringResource =
        "关闭墨指画中画小窗，停止连续复制（静默、无需切到前台）。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // 只在确实在跑时才发停止指令，避免「已关闭」时残留指令在下次开启误触发。
        if QPSharedHistory.livePipState() {
            QPSharedHistory.markPipStopCommand()
        }
        return .result()
    }
}

/// 切换连续复制：在开 / 关之间翻转（开启时会短暂切到墨指前台）。
final class ToggleContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "切换连续复制"
    static var description: LocalizedStringResource =
        "在开 / 关之间翻转连续复制（开启时会短暂切到墨指前台）。"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // 以主 App 真实的运行态为准翻转；意图随 App 启动在进程内运行，读得到。
        let running = PiPManager.shared.running
        await MainActor.run {
            if running {
                PiPManager.shared.stop()
            } else {
                PiPManager.shared.start()
            }
        }
        return .result()
    }
}

// MARK: - 快捷指令里的「墨指」入口与建议短语
//
// 注册后：打开「快捷指令」App → 右上角「+」→ 搜索「墨指」即可看到下列动作；
// 也可在「自动化」里引用，或用 Siri 念出短语唤起。
struct MozhiAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        let togglePhrases: [AppShortcutPhrase<ToggleContinuousCopyIntent>] = [
            "用 \(.applicationName) 切换连续复制",
            "切换连续复制",
            "翻转墨指连续复制",
            "连续复制 开关"
        ]
        let startPhrases: [AppShortcutPhrase<StartContinuousCopyIntent>] = [
            "用 \(.applicationName) 开启连续复制",
            "开启连续复制",
            "打开墨指连续复制",
            "开始墨指连续复制"
        ]
        let stopPhrases: [AppShortcutPhrase<StopContinuousCopyIntent>] = [
            "用 \(.applicationName) 关闭连续复制",
            "关闭连续复制",
            "停止墨指连续复制",
            "结束墨指连续复制"
        ]
        AppShortcut(
            intent: ToggleContinuousCopyIntent(),
            phrases: togglePhrases,
            shortTitle: "切换连续复制",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: StartContinuousCopyIntent(),
            phrases: startPhrases,
            shortTitle: "开启连续复制",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopContinuousCopyIntent(),
            phrases: stopPhrases,
            shortTitle: "关闭连续复制",
            systemImageName: "stop.circle"
        )
    }
}
