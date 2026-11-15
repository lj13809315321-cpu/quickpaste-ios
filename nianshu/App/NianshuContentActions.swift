import Foundation
import UIKit

// MARK: - 内容加工 / 逐条队列 / 推给输入法（纯逻辑层）
//
// 这一层给「快捷指令动作库」里的新动作共用：
//   · NianshuText   —— 把本次/最近这些文字加工成更好用的形状（去重、链接、验证码、编号、JSON…）；
//   · NianshuQueue  —— 记住「本次这几条 + 现在指到第几条」，点一下换一条；
//   · NianshuPush   —— 所有手动写回剪贴板的动作统一从这里走，保证不跟后台监听打架。
//
// ★ 关键边界：iOS 剪贴板只有一个槽位。任何时候写回都必须：
//   ① 作废挂起的「自动实时推」，否则 1.5 秒后会被合并整坨覆盖掉刚推的单条；
//   ② 走 AutoPushMerge.writeMerged 先登记指纹再写，后台 0.4s 轮询会整条跳过，
//      不会把推回去的原文又收一遍、把「本次」顺序打乱。

// MARK: 文本加工

enum NianshuText {

    /// 上限 10 万字，避免极端情况撑爆系统剪贴板。
    static func capped(_ s: String) -> String {
        s.count > 100_000 ? String(s.prefix(100_000)) : s
    }

    /// 清洗成输入法好用的干净纯文本：去首尾空白、行首行尾空白、压掉连续空行。
    static func clean(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for l in lines {
            // 开头空行、连续空行都不要
            if l.isEmpty, out.isEmpty || (out.last?.isEmpty ?? false) { continue }
            out.append(l)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保序去重（同样的内容复制了两遍只留一条）。
    static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where !seen.contains(x) {
            seen.insert(x)
            out.append(x)
        }
        return out
    }

    static func isLink(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    /// 只留链接：整条就是链接直接收，否则按空白拆开把里面的链接挑出来。
    static func links(in texts: [String]) -> [String] {
        let trimSet = CharacterSet(charactersIn: "，。！？、；：\"'()[]<>《》")
        var out: [String] = []
        for t in texts {
            let whole = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLink(whole) { out.append(whole); continue }
            for token in t.components(separatedBy: .whitespacesAndNewlines) {
                let s = token.trimmingCharacters(in: trimSet)
                if isLink(s) { out.append(s) }
            }
        }
        return dedup(out)
    }

    /// 从一段文字里挑出所有 4–6 位连续数字（正好是常见短信验证码长度）。
    /// 纯字符扫描，不用正则，避免不同 iOS 版本 ICU 语法差异。
    static func digitRuns(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() {
            if cur.count >= 4 && cur.count <= 6 { out.append(cur) }
            cur = ""
        }
        for ch in s {
            let v = ch.unicodeScalars.first?.value ?? 0
            let isASCIIDigit = ch.unicodeScalars.count == 1 && v >= 48 && v <= 57
            if isASCIIDigit { cur += String(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// 最新的一条验证码：按「新 → 旧」找，每条里取最后一个数字串。
    static func latestCode(in texts: [String]) -> String {
        for t in texts.reversed() {
            if let c = digitRuns(t).last { return c }
        }
        return ""
    }

    /// 取原始范围：count <= 0 = 本次这一轮全部；>0 = 最近 N 条。都按复制先后正序。
    static func baseTexts(count: Int) -> [String] {
        count <= 0 ? LocalStore.currentSessionTexts() : LocalStore.recentTexts(count)
    }

    /// 加工模式：
    ///   0 原样 / 1 去重 / 2 只留链接 / 3 只留验证码数字 / 4 关键词过滤（配合 keyword）
    ///   / 5 每条清洗成干净纯文本 / 6 去空行+清洗。
    /// order：0 正序（旧 → 新）/ 1 倒序（新 → 旧）。
    static func transform(_ base: [String], mode: Int, order: Int, keyword: String) -> [String] {
        var xs = base
        switch mode {
        case 1: xs = dedup(xs)
        case 2: xs = links(in: xs)
        case 3: xs = dedup(xs.flatMap { digitRuns($0) })
        case 5: xs = xs.map(clean)
        case 6: xs = xs.map(clean).filter { !$0.isEmpty }
        default: break   // 0 原样 / 4 靠下面的 keyword 生效
        }
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { xs = xs.filter { $0.localizedCaseInsensitiveContains(k) } }
        if order == 1 { xs = Array(xs.reversed()) }
        return xs
    }

    /// 拼接样式：
    ///   0 跟随页面「每条之间」设置 / 1 编号列表 / 2 逗号 / 3 空格
    ///   / 4 JSON 数组 / 5 只留最新一条干净纯文本 / 6 强制换行。
    static func join(_ texts: [String], style: Int) -> String {
        switch style {
        case 1: return numbered(texts)
        case 2: return texts.joined(separator: "，")
        case 3: return texts.joined(separator: " ")
        case 4: return jsonArray(texts)
        case 5: return clean(texts.last ?? "")
        case 6: return texts.joined(separator: "\n")
        default:
            let mode = UserDefaults.standard.integer(forKey: "ns.mergeSeparator")
            return LocalStore.mergedText(texts, separatorMode: mode)
        }
    }

    static func numbered(_ texts: [String]) -> String {
        texts.enumerated().map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
    }

    static func jsonArray(_ texts: [String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: texts, options: []),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    /// 「取智能加工文本」一步到位：范围 → 加工 → 排序 → 拼接 → 限长。
    static func smartText(count: Int, mode: Int, style: Int, order: Int, keyword: String) -> String {
        let xs = transform(baseTexts(count: count), mode: mode, order: order, keyword: keyword)
        return capped(join(xs, style: style))
    }
}

// MARK: 逐条队列

enum NianshuQueue {

    private static let indexKey = "ns.queueIndex"

    /// 1-based：0 表示还没开始推过。存 UserDefaults，快捷指令冷启动也接着上一次。
    static func index() -> Int {
        max(0, UserDefaults.standard.integer(forKey: indexKey))
    }

    static func setIndex(_ i: Int) {
        UserDefaults.standard.set(max(0, i), forKey: indexKey)
    }

    /// 队列内容 = 本次这一轮的文字，按复制先后正序（旧 → 新）。
    static func items() -> [String] { LocalStore.currentSessionTexts() }

    /// step：0 下一条 / -1 上一条 / -2 回到第一条 / >0 跳到第 N 条。
    /// 到头会绕回第 1 条，符合「轮着来」的直觉。
    static func position(step: Int) -> (text: String, index: Int, total: Int)? {
        let xs = items()
        guard !xs.isEmpty else { return nil }
        let total = xs.count
        let cur = min(max(index(), 0), total)
        let next: Int
        if step > 0 {
            next = min(step, total)
        } else if step == -2 {
            next = 1
        } else if step == -1 {
            next = cur <= 1 ? total : cur - 1
        } else {
            next = cur >= total || cur == 0 ? 1 : cur + 1
        }
        setIndex(next)
        return (NianshuText.clean(xs[next - 1]), next, total)
    }

    /// 推一条干净纯文本到剪贴板，并在画中画小窗/页面上提示现在是第几条。
    @discardableResult
    static func pushAndWrite(step: Int) -> Bool {
        guard let r = position(step: step) else {
            PiPManager.shared.note("本次还没有文字：先复制几条，再用逐条队列")
            return false
        }
        NianshuPush.write(r.text,
                          note: "已推第 \(r.index)/\(r.total) 条到剪贴板，去输入法浮条粘贴")
        return true
    }
}

// MARK: 手动写回剪贴板的统一入口

enum NianshuPush {

    /// 供「推干净单条 / 推编号列表 / 推验证码 / 逐条队列」共用。
    /// 调用点都在主线程（页面按钮或 AppIntent 的 MainActor.run）。
    static func write(_ text: String, note: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            PiPManager.shared.note("没有可推送的文字：本次还没收文字，或只收到图片 / 文件")
            return
        }
        // ① 手动推优先：作废挂起的自动写入，并清掉写前核对的期望原文，
        //    保证刚推的单条不会被 1.5 秒后的合并整坨覆盖。
        AutoPushMerge.cancel()
        AutoPushMerge.setExpectedRaw(nil)
        // ② 先登记指纹再写：后台轮询认出是自己写的会整条跳过，不回环、不打乱「本次」顺序。
        AutoPushMerge.writeMerged(t)
        PiPManager.shared.note(note)
    }
}
