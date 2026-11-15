import Foundation
import AppIntents

// MARK: - 连续复制 · 快捷指令接入（独立 App 版）
//
// 让用户能在 iOS「快捷指令」App 里搜到「粘鼠」，并一键开关画中画连续复制；
// 也可被 Siri 语音唤起、放进「自动化」（如：连上家里 WiFi 自动开启）。
//
// 实现要点：
//  · 意图全部放在【主 App】(Nianshu target)，不走键盘扩展——键盘扩展里起不了画中画。
//  · 「开启 / 切换」会把 App 短暂拉到前台（openAppWhenRun），因为画中画必须
//    由前台 App 的窗口承载，和你在 App 内点开启是同一套逻辑。
//  · 复用既有 PiPManager.shared.start() / stop()，状态自动同步。
//  · 意图类不加 @MainActor（否则与快捷指令 Provider 实例化冲突），UI 调用用
//    MainActor.run 切到主线程。

/// 开启连续复制：拉起画中画小窗开始跨 App 抓取剪贴板。
final class StartContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "开启连续复制"
    static var description: LocalizedStringResource =
        "拉起粘鼠画中画小窗，开始跨 App 连续复制（会短暂切到粘鼠前台以启动画中画，随后自动跳回来源 App）。"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // 窗口就绪与画中画重试已内置于 PiPManager.start()；启动后自动跳回来源 App。
        await MainActor.run {
            PiPManager.shared.start()
            AppRootView.returnToSourceAfterPipStart()
        }
        return .result()
    }
}

/// 关闭连续复制：关掉画中画小窗。用「就地停止」直接收尾，无需切到前台、真生效。
final class StopContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭连续复制"
    static var description: LocalizedStringResource =
        "关闭粘鼠画中画小窗，停止连续复制（静默、无需切到前台）。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // 单进程 App：意图与主 App 是同一个 PiPManager 实例，直接同步收尾即可。
        await MainActor.run {
            PiPManager.shared.forceStopFromShortcut()
        }
        return .result()
    }
}

/// 切换连续复制：在开 / 关之间翻转。
/// ★ iOS 18 SDK 要求 `openAppWhenRun` 必须是【静态编译期常量】，不能按当前状态
///   动态计算（否则编译报 "must have a compile-time static value"），所以统一 true。
/// ★ 判活用【本进程真实 running/starting】为准，不要用任何剪贴板心跳。
/// ★ 关闭走 `forceStopFromShortcut()` 同步全量收尾，避免刚关又被 startIfWanted 拉起。
final class ToggleContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "切换连续复制"
    static var description: LocalizedStringResource =
        "在开 / 关之间翻转连续复制（开启或关闭后都会自动跳回来源 App）。"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let mgr = PiPManager.shared
            let isRunning = mgr.isActive
            if isRunning {
                // 关闭：同步清干净所有「还想开」的标记。
                mgr.forceStopFromShortcut()
                // 开关控制「关完是否自动跳回来源 App」。
                //   默认关（不跳）→ 停在粘鼠主 App，能看到状态；
                //   打开 → 关完立刻回来源 App。
                //   注意 openAppWhenRun=true 那一次拉起是系统静态要求，开关管不了。
                if UserDefaults.standard.bool(forKey: "ns.pipToggleReturnOnClose") {
                    let target = LocalStore.defaultReturnBundleId()
                    if let target = target, !target.isEmpty {
                        AppRootView.openHostApp(target)
                    } else {
                        PiPManager.shared.note("没识别出来源 App：可在本页「返回来源 App」设个默认目标")
                    }
                }
            } else {
                // 开启：画中画必须要前台窗口，启动后自动跳回来源 App。
                mgr.start()
                AppRootView.returnToSourceAfterPipStart()
            }
        }
        return .result()
    }
}

/// 小开关：一键开 / 关连续复制（与 App 内页面上的「小开关」同义）。
/// 单独注册成快捷指令动作，方便在「快捷指令」App 里搜到、被 Siri / 自动化唤起。
final class SmallSwitchIntent: AppIntent {
    static var title: LocalizedStringResource = "小开关"
    static var description: LocalizedStringResource =
        "开启或关闭粘鼠连续复制（和 App 内的「小开关」是同一个开关）。"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let mgr = PiPManager.shared
            if mgr.isActive {
                mgr.forceStopFromShortcut()
            } else {
                mgr.start()
                AppRootView.returnToSourceAfterPipStart()
            }
        }
        return .result()
    }
}

/// ① 单独「暂停」：画中画小窗与后台保活都不关，只是不再读取剪贴板。
/// 状态写进 UserDefaults，App 在后台 / 未打开时由快捷指令直接切换也生效。
final class PauseContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "暂停收录"
    static var description: LocalizedStringResource =
        "让粘鼠暂时停止收录新复制的内容，画中画小窗保持不消失（无需切到前台）。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { PiPManager.shared.pause() }
        return .result()
    }
}

/// ② 单独「启动」：恢复被暂停的剪贴板收录，不用重新开启画中画。
/// 标题按用户说的「启动」来，等价于上一版的「继续连续复制」，两种叫法都能唤起。
final class ResumeContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "启动收录"
    static var description: LocalizedStringResource =
        "启动（继续）粘鼠的剪贴板收录，与「暂停收录」相对；画中画小窗本来就没关，无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { PiPManager.shared.resume() }
        return .result()
    }
}

/// ③ 「切换暂停启动」开关：一次动作在 暂停 ↔ 启动 之间翻转。
/// 判状态以 UserDefaults 里的持久值为准（App 被系统重启、画中画还没起来时也不会翻错），
/// 全程不需要切到前台，适合放进「自动化」和 Siri。
final class TogglePauseContinuousCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "切换暂停启动"
    static var description: LocalizedStringResource =
        "在「暂停收录」和「启动收录」之间一键翻转：暂停时会自动恢复，正在收录时会自动暂停。画中画小窗与后台保活都不受影响，无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { PiPManager.shared.togglePause() }
        return .result()
    }
}

/// ⑧ 复制本次合并：把本轮复制的文字按先后拼成一条，直接写回系统剪贴板。
/// 不用在快捷指令里逐条挑——范围固定为「本次这一轮」的全部文字。
final class CopyMergedSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "复制本次合并"
    static var description: LocalizedStringResource =
        "把本次连续复制收进来的文字按先后拼成一条完整内容，直接写回系统剪贴板，去目标 App 粘贴即可（无需切到前台、无需手动挑条目）。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            LocalStore.writeMergedToPasteboard(LocalStore.mergedSessionText())
        }
        return .result()
    }
}

/// ⑨ 复制最近合并：条数由快捷指令里的参数决定，默认 0 = 本次全部。
/// 「怎么选这几条」不用在快捷指令里逐条勾选，填一个数字即可。
struct CopyRecentMergedIntent: AppIntent {
    static var title: LocalizedStringResource = "复制最近合并"
    static var description: LocalizedStringResource =
        "把最近 N 条文字拼成一条写回系统剪贴板；条数填 0 表示取本次这一轮的全部。"
    static var openAppWhenRun: Bool = false

    // ★ @Parameter 的包装器不接受 `= 0` 这种 wrappedValue 默认值
    //   （Xcode 16.4 报 extra argument 'wrappedValue' in call）。
    //   标准写法：属性不写默认值，在 init() 里赋，且用 struct 避免
    //   Sendable class 的可变存储属性告警。
    @Parameter(title: "条数")
    var count: Int

    init() { self.count = 0 }

    func perform() async throws -> some IntentResult {
        let n = count
        await MainActor.run {
            LocalStore.writeMergedToPasteboard(LocalStore.mergedRecentText(n))
        }
        return .result()
    }
}

/// ⑩ 恢复最后一次复制：开着「自动把本次合并推回剪贴板」时，
/// 一键把系统剪贴板从合并整条换回最后复制的那一条原文，方便粘单条。
final class RestoreLastRawCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "恢复最后一次复制"
    static var description: LocalizedStringResource =
        "把系统剪贴板还原成最后一次复制的单条原文；开着自动实时推送时，用来临时粘单条。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { LocalStore.restoreLastRawCopyToPasteboard() }
        return .result()
    }
}

// MARK: ⑪⑫⑬ - 两种推送方式的快捷指令开关（手动推 / 自动实时推）
//
// 不用进 App 翻设置：在快捷指令、Siri、自动化里点一下就能换方式。
// 三个动作沿用「暂停 / 启动 / 切换暂停启动」的习惯：单独开、单独关、一键切换。
// 都是后台静默执行，不需要切到前台，也不改当前剪贴板内容（只改「以后怎么做」）。

/// ⑪ 开实时推送：切到「停手 1.5 秒自动把本次合并推回剪贴板」。
final class EnableAutoPushMergeIntent: AppIntent {
    static var title: LocalizedStringResource = "开实时推送"
    static var description: LocalizedStringResource =
        "把推回剪贴板的方式切成「自动实时推」：停手约 1.5 秒后自动把本次合并写回系统剪贴板。会顺手打开「组装成单独一条」，无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            LocalStore.setAutoPushMerge(true)
            PiPManager.shared.note("已切到「自动实时推」：停手 1.5 秒自动写回合并结果")
        }
        return .result()
    }
}

/// ⑫ 关实时推送：切回「手动推」（点页面按钮 / 跑复制合并动作才推）。
final class DisableAutoPushMergeIntent: AppIntent {
    static var title: LocalizedStringResource = "关实时推送"
    static var description: LocalizedStringResource =
        "把推回剪贴板的方式切回「手动推」：不再自动写回剪贴板，想推时点页面按钮或跑「复制本次合并」。会立刻作废还没到点的自动写入，无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            LocalStore.setAutoPushMerge(false)
            PiPManager.shared.note("已切回「手动推」：不再自动写回剪贴板")
        }
        return .result()
    }
}

/// ⑬ 切换实时推送 ★ 主推的那一个开关：点一下变自动、再点一下变手动。
/// 判状态以 UserDefaults 里的持久值为准，App 被系统重启后也不会翻错。
final class ToggleAutoPushMergeIntent: AppIntent {
    static var title: LocalizedStringResource = "切换实时推送"
    static var description: LocalizedStringResource =
        "在「手动推」和「自动实时推」之间一键翻转：手动时切成停手 1.5 秒自动写回，自动时切回手动。不用切到前台，也不改写当前剪贴板内容。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let on = LocalStore.toggleAutoPushMerge()
            PiPManager.shared.note(on
                ? "已切到「自动实时推」：停手 1.5 秒自动写回合并结果"
                : "已切回「手动推」：不再自动写回剪贴板")
        }
        return .result()
    }
}

// MARK: - 快捷指令里的「粘鼠」入口与建议短语
//
// 注册后：打开「快捷指令」App → 右上角「+」→ 搜索「粘鼠」即可看到下列动作；
// 也可在「自动化」里引用，或用 Siri 念出短语唤起。
//
// ★ iOS 硬限制：一个 App 的 AppShortcutsProvider 最多【10 个】AppShortcut，
//   超了 appintentsmetadataprocessor 会直接报
//   "Found N App Shortcuts, but each app may have at most 10" 让整个构建失败。
//   所以这里只放 10 个「能用 Siri 语音唤起」的；其余 AppIntent 照样是快捷指令
//   动作库里的正常动作（快捷指令 → + → 搜索粘鼠 → 动作里都能找到，也能放进
//   自动化），只是不带语音短语：
//     复制最近合并 / 开实时推送 / 关实时推送  ← 这三个不占名额。
//   功能一个没少，区别只是这三个不能用 Siri 念出来，得在快捷指令里点。
struct NianshuAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SmallSwitchIntent(),
            phrases: [
                "用 \(.applicationName) 小开关",
                "\(.applicationName) 小开关",
                "\(.applicationName) 开关连续复制",
                "\(.applicationName) 打开或关闭连续复制"
            ],
            shortTitle: "小开关",
            systemImageName: "rectangle.on.rectangle"
        )
        AppShortcut(
            intent: ToggleContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 切换连续复制",
                "\(.applicationName) 切换连续复制",
                "\(.applicationName) 翻转连续复制",
                "\(.applicationName) 连续复制开关"
            ],
            shortTitle: "切换连续复制",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: StartContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 开启连续复制",
                "\(.applicationName) 开启连续复制",
                "\(.applicationName) 打开连续复制",
                "\(.applicationName) 开始连续复制"
            ],
            shortTitle: "开启连续复制",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 关闭连续复制",
                "\(.applicationName) 关闭连续复制",
                "\(.applicationName) 停止连续复制",
                "\(.applicationName) 结束连续复制"
            ],
            shortTitle: "关闭连续复制",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: PauseContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 暂停收录",
                "\(.applicationName) 暂停收录",
                "\(.applicationName) 暂停连续复制",
                "\(.applicationName) 暂停启动",
                "\(.applicationName) 先别抓剪贴板"
            ],
            shortTitle: "暂停收录",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 启动收录",
                "\(.applicationName) 启动收录",
                "\(.applicationName) 启动连续复制",
                "\(.applicationName) 继续连续复制",
                "\(.applicationName) 恢复收录",
                "\(.applicationName) 接着抓剪贴板"
            ],
            shortTitle: "启动收录",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: TogglePauseContinuousCopyIntent(),
            phrases: [
                "用 \(.applicationName) 切换暂停启动",
                "\(.applicationName) 切换暂停启动",
                "\(.applicationName) 切换暂停收录",
                "\(.applicationName) 暂停启动开关",
                "\(.applicationName) 翻转收录开关"
            ],
            shortTitle: "切换暂停启动",
            systemImageName: "repeat.circle"
        )
        AppShortcut(
            intent: CopyMergedSessionIntent(),
            phrases: [
                "用 \(.applicationName) 复制本次合并",
                "\(.applicationName) 复制本次合并",
                "\(.applicationName) 合并本次复制",
                "\(.applicationName) 把本次合并到剪贴板"
            ],
            shortTitle: "复制本次合并",
            systemImageName: "doc.on.clipboard"
        )
        // 「复制最近合并」不占语音短语名额（见上方 iOS 10 个上限的说明），
        // 它仍是快捷指令动作库里能搜到、能填「条数」、能放进自动化的正常动作。
        AppShortcut(
            intent: RestoreLastRawCopyIntent(),
            phrases: [
                "用 \(.applicationName) 恢复最后一次复制",
                "\(.applicationName) 恢复最后一次复制",
                "\(.applicationName) 还原单条",
                "\(.applicationName) 粘回最后一条"
            ],
            shortTitle: "恢复最后一次复制",
            systemImageName: "arrow.uturn.backward.circle"
        )
        // 「开实时推送」「关实时推送」同样不占语音短语名额：两个动作仍在
        // 快捷指令动作库里，适合拖进「到家自动开 / 开会先关」这类自动化。
        // 语音名额只留给最常用、最符合「一个开关」诉求的「切换实时推送」。
        AppShortcut(
            intent: ToggleAutoPushMergeIntent(),
            phrases: [
                "用 \(.applicationName) 切换实时推送",
                "\(.applicationName) 切换实时推送",
                "\(.applicationName) 切换推送方式",
                "\(.applicationName) 推送方式开关",
                "\(.applicationName) 实时推送开关"
            ],
            shortTitle: "切换实时推送",
            systemImageName: "arrow.triangle.2.circlepath.circle"
        )
    }
}
