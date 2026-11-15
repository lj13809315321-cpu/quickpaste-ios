import Foundation
import AppIntents

// MARK: - 快捷指令【动作库】补充动作（不占 Siri 语音名额）
//
// iOS 硬限制：一个 App 最多 10 个 AppShortcut（能念 Siri 短语的），已经用满。
// 这里这批全部只是 AppIntent —— 在「快捷指令」App →「+」→ 搜索「粘鼠」里
// 照样是正常动作，能填参数、能拖进自动化、能一个接一个串起来，只是不能用
// Siri 念出来（得点一下）。
//
// 分三类：
//   ① 返回文本型：不写剪贴板，把内容【交回快捷指令】，后面可以接「拷贝到剪贴板」
//      「存到文件」「发微信」「加到备忘录」「打开链接」等任意动作；
//   ② 输入法友好推送：直接写回系统剪贴板，只放一条干净纯文本 / 编号列表 / 验证码；
//   ③ 逐条队列：每按一次换一条，正打字时连点「推下一条」逐条贴。
//
// ★ 所有写回剪贴板的动作都走 NianshuPush.write：先作废挂起的自动写入、
//   再登记指纹后写，保证不与后台 0.4s 监听打架（详见 NianshuContentActions.swift）。

// MARK: ① 返回文本型（把内容交回快捷指令，自己不碰剪贴板）

/// 取本次合并文本：最常用的「取内容」入口，后面接什么动作都行。
struct GetMergedSessionTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取本次合并文本"
    static var description: LocalizedStringResource =
        "把本次连续复制的文字按先后拼成一条文本【返回给快捷指令】；不写剪贴板，后面可接「拷贝到剪贴板」「存储文件」「发送微信」等任意动作。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: LocalStore.mergedSessionText())
    }
}

/// 取最近 N 条文本：条数填 0 = 本次全部。
struct GetRecentMergedTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取最近 N 条文本"
    static var description: LocalizedStringResource =
        "把最近 N 条文字拼成一条文本【返回给快捷指令】；条数填 0 表示取本次这一轮的全部。"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "条数（0 = 本次全部）")
    var count: Int

    init() { self.count = 0 }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let n = count
        return .result(value: NianshuText.smartText(count: n, mode: 0, style: 0,
                                                    order: 0, keyword: ""))
    }
}

/// 取本次第 N 条：只返回一条干净纯文本，不写剪贴板、不动队列位置。
struct GetSessionItemTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取本次第 N 条"
    static var description: LocalizedStringResource =
        "按复制先后取本次第 N 条的干净纯文本【返回给快捷指令】（1 = 最早那条）；不写剪贴板。"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "第几条（从 1 开始）")
    var index: Int

    init() { self.index = 1 }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let xs = LocalStore.currentSessionTexts()
        let i = max(1, index)
        let t = (i <= xs.count) ? NianshuText.clean(xs[i - 1]) : ""
        return .result(value: t)
    }
}

/// 取本次链接：整条是链接、或文本里夹着的链接都挑出来，去重后按行返回。
struct GetLinksTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取本次链接"
    static var description: LocalizedStringResource =
        "把本次复制内容里的网址挑出来，去重后按行【返回给快捷指令】，可直接接「打开 URL」「存储文件」。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let xs = NianshuText.links(in: LocalStore.currentSessionTexts())
        return .result(value: xs.joined(separator: "\n"))
    }
}

/// 取最新验证码：只返回 4–6 位数字，正好喂给输入法的验证码浮条。
struct GetVerificationCodeTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取最新验证码"
    static var description: LocalizedStringResource =
        "从本次复制的文字里找出最新的 4–6 位验证码数字【返回给快捷指令】；不写剪贴板。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: NianshuText.latestCode(in: LocalStore.currentSessionTexts()))
    }
}

/// 取去重文字：同样内容复制多遍只留一条，按当前分隔方式拼好返回。
struct GetDedupedTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取去重文字"
    static var description: LocalizedStringResource =
        "本次文字保序去重后拼成一条文本【返回给快捷指令】；重复复制过的内容只留一条。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let xs = NianshuText.dedup(LocalStore.currentSessionTexts())
        let mode = UserDefaults.standard.integer(forKey: "ns.mergeSeparator")
        return .result(value: NianshuText.capped(LocalStore.mergedText(xs, separatorMode: mode)))
    }
}

/// 取智能加工文本：一个动作带齐范围 / 加工 / 拼接 / 排序 / 关键词。
/// 参数都是数字，在快捷指令里直接改数字即可，不用记一堆动作名。
struct GetSmartTextIntent: AppIntent {
    static var title: LocalizedStringResource = "取智能加工文本"
    static var description: LocalizedStringResource =
        "一个动作搞定加工：条数（0=本次全部）、加工模式（0原样/1去重/2只链接/3只验证码/5清洗每条）、拼接样式（0默认/1编号/2逗号/3空格/4JSON数组/5只要最新一条/6换行）、顺序（0正序/1倒序）、关键词（留空不过滤）。结果【返回给快捷指令】。"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "条数（0 = 本次全部）")
    var count: Int
    @Parameter(title: "加工模式 0原样 1去重 2链接 3验证码 5清洗")
    var mode: Int
    @Parameter(title: "拼接样式 0默认 1编号 2逗号 3空格 4JSON 5最新一条 6换行")
    var style: Int
    @Parameter(title: "顺序 0正序 1倒序")
    var order: Int
    @Parameter(title: "关键词（留空 = 不过滤）")
    var keyword: String

    init() {
        self.count = 0
        self.mode = 0
        self.style = 0
        self.order = 0
        self.keyword = ""
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let c = count, m = mode, s = style, o = order, k = keyword
        return .result(value: NianshuText.smartText(count: c, mode: m, style: s,
                                                    order: o, keyword: k))
    }
}

// MARK: ② 输入法友好推送（直接写回系统剪贴板，一次只放一条干净内容）

/// 推干净单条：把最后一次复制的原文清洗后写回剪贴板，供输入法浮条/候选栏取用。
final class PushCleanTextIntent: AppIntent {
    static var title: LocalizedStringResource = "推干净单条到剪贴板"
    static var description: LocalizedStringResource =
        "把最后复制的那条文字去掉多余空白与空行，写成一条干净纯文本放进系统剪贴板，打字时从输入法浮条粘贴即可；无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let raw = LocalStore.lastRawText() ?? ""
            NianshuPush.write(NianshuText.clean(raw),
                              note: "已推一条干净纯文本到剪贴板（输入法可直接取用）")
        }
        return .result()
    }
}

/// 推编号列表：本次所有条目前加 1. 2. 3.，输入法剪贴板面板一次看全。
final class PushNumberedSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "推编号列表到剪贴板"
    static var description: LocalizedStringResource =
        "把本次这一轮的文字加上编号（1. 2. 3. …）拼成一条写回系统剪贴板，输入法剪贴板面板里能一次看全；无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let xs = LocalStore.currentSessionTexts()
            let text = NianshuText.capped(NianshuText.numbered(xs))
            NianshuPush.write(text, note: "已推 \(xs.count) 条编号列表到剪贴板")
        }
        return .result()
    }
}

/// 推验证码：只把最新的 4–6 位数字写回剪贴板，正好给输入法验证码浮条。
final class PushVerificationCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "推验证码到剪贴板"
    static var description: LocalizedStringResource =
        "从本次复制的文字里提取最新的 4–6 位验证码，只把这个数字写回系统剪贴板，喂给输入法的验证码浮条；无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let code = NianshuText.latestCode(in: LocalStore.currentSessionTexts())
            NianshuPush.write(code, note: "已推验证码到剪贴板，去输入法浮条点一下插入")
        }
        return .result()
    }
}

// MARK: ③ 逐条队列（每按一次换一条，正打字时连点「推下一条」逐条贴）
//
// iOS 不告诉 App「用户刚粘贴了」，所以做不到「粘完自动换下一条」；
// 这里改成点一下换一条，可放主屏幕 / 背面轻点 / 自动化，一样快。

final class PushFirstItemIntent: AppIntent {
    static var title: LocalizedStringResource = "推第一条（队列回到开头）"
    static var description: LocalizedStringResource =
        "把逐条队列拨回第 1 条，并把那一条干净纯文本写回系统剪贴板；无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { NianshuQueue.pushAndWrite(step: -2) }
        return .result()
    }
}

final class PushNextItemIntent: AppIntent {
    static var title: LocalizedStringResource = "推下一条"
    static var description: LocalizedStringResource =
        "把本次这几条的【下一条】干净纯文本写回系统剪贴板，到末尾自动绕回第 1 条；正打字时连点它逐条贴，无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { NianshuQueue.pushAndWrite(step: 0) }
        return .result()
    }
}

final class PushPreviousItemIntent: AppIntent {
    static var title: LocalizedStringResource = "推上一条"
    static var description: LocalizedStringResource =
        "把逐条队列退回【上一条】并写回系统剪贴板，在第 1 条时会绕回最后一条；无需切到前台。"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { NianshuQueue.pushAndWrite(step: -1) }
        return .result()
    }
}

/// 带 @Parameter 的意图统一用 struct（避免 Sendable class 可变存储属性告警）。
struct PushItemAtIndexIntent: AppIntent {
    static var title: LocalizedStringResource = "推第 N 条"
    static var description: LocalizedStringResource =
        "直接跳到本次第 N 条（1 = 最早那条），把那一条干净纯文本写回系统剪贴板；无需切到前台。"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "第几条（从 1 开始）")
    var index: Int

    init() { self.index = 1 }

    func perform() async throws -> some IntentResult {
        let n = index
        await MainActor.run { NianshuQueue.pushAndWrite(step: max(1, n)) }
        return .result()
    }
}
