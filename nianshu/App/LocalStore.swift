import Foundation
import UIKit

// MARK: - 粘鼠 · 单进程本地存储
//
// 旧「墨指」用 App Group 文件 + 剪贴板自定义类型做**跨进程**通道（主 App ↔ 键盘扩展）。
// 粘鼠是**单 target、无键盘扩展**的独立 App，只有一个进程，整套跨进程通道都不需要：
//   · 历史 / 删除墓碑 / 开关 / 返回来源 App 全部用 UserDefaults + 本地 JSON 文件；
//   · 绝不用 UIPasteboard 给自己发指令（那是 v1.8.44 修的「冲掉用户剪贴板」的坑）。
//
// 这里集中实现 PiPManager / SettingsViews / NianshuIntents / PiPControlView
// 里所有原来对 QPSharedHistory 的调用，签名尽量一一对应，方便平移。

enum LocalStore {

    // MARK: - 历史（主 App 唯一数据源）

    /// 单条：文本 + 真实收录时间戳（秒）。时间戳是「本次/上次/上上次」徽标与
    /// 「刚刚 / 3 分钟前」相对时间的基础，绝不能退化成「每次现算 now」，
    /// 否则所有条目都会显示「刚刚」（v1.8.43 的血泪教训）。
    private struct StoredItem: Codable {
        var t: String
        var ts: Double
    }

    private static let historyKey = "ns.history.v1"

    /// 读全部历史（内存镜像，列表显示用）。
    private static func loadItems() -> [StoredItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let arr = try? JSONDecoder().decode([StoredItem].self, from: data) else { return [] }
        return arr
    }

    private static func saveItems(_ arr: [StoredItem]) {
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    /// 合并视图：去重（指纹，取时间较新者）、过滤墓碑、按时间倒序。
    /// 单进程下不再有「共享通道」一份，直接返回本地即可。
    static func allItems() -> [(text: String, ts: Double)] {
        let marks = deletedMarks()
        var seen = Set<String>()
        var out: [(String, Double)] = []
        for it in loadItems().sorted(by: { $0.ts > $1.ts }) {
            let fp = fingerprint(it.t)
            guard !marks.contains(fp), !seen.contains(fp) else { continue }
            seen.insert(fp)
            out.append((it.t, it.ts))
        }
        return out
    }

    /// 收录一条新复制的文本。内容没变就绝不写，否则 0.4s 轮询会无限循环。
    /// 返回 true 表示确实是新条目（调用方据此让计数 +1）。
    @discardableResult
    static func append(_ text: String) -> Bool {
        var arr = loadItems()
        if arr.first?.t == text { return false }
        arr.removeAll { $0.t == text }
        arr.insert(StoredItem(t: text, ts: Date().timeIntervalSince1970), at: 0)
        if arr.count > 200 { arr = Array(arr.prefix(200)) }
        saveItems(arr)
        return true
    }

    /// 清空本地历史（不动系统剪贴板正文）。
    static func clearHistory() {
        saveItems([])
    }

    /// 批量删除：写墓碑 + 从本地历史移除。
    static func delete(_ texts: [String]) {
        var marks = deletedMarks()
        for t in texts { marks.insert(fingerprint(t)) }
        saveDeletedMarks(marks)
        let fps = Set(texts.map { fingerprint($0) })
        saveItems(loadItems().filter { !fps.contains(fingerprint($0.t)) })
    }

    // MARK: - 指纹 / 墓碑

    /// 用完整内容当指纹，避免两条长文本前 N 字相同被误判成同一条（v1.8.43 修过）。
    static func fingerprint(_ text: String) -> String { text }

    static func deletedMarks() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ns.deletedMarks") ?? [])
    }

    private static func saveDeletedMarks(_ s: Set<String>) {
        let capped = Array(s.prefix(500))
        UserDefaults.standard.set(capped, forKey: "ns.deletedMarks")
    }

    // MARK: - 一轮连续复制算一次（按开启轮次给条目标记）

    /// 一次连续复制 = 画中画从起到停的这一轮。同轮抓到的条目都算「本次」。
    /// 只记最近 3 轮开启时刻，靠「条目收录时刻落在哪个区间」判轮次，不用给每条加字段。
    static let sessionStartsKey = "ns.pipSessionStarts"

    /// 最近 3 轮开启时刻（秒），降序：[本次, 上次, 上上次]。
    static func pipSessionStarts() -> [Double] {
        let raw = UserDefaults.standard.array(forKey: sessionStartsKey) ?? []
        return Array(raw.compactMap { ($0 as? NSNumber)?.doubleValue }.prefix(3))
    }

    /// 画中画真正起来 = 新一轮开始。2 秒内的重复回调算同一轮，不重复记。
    static func markPipSessionStart() {
        let now = Date().timeIntervalSince1970
        var a = pipSessionStarts()
        if let last = a.first, now - last < 2 { return }
        a.insert(now, at: 0)
        UserDefaults.standard.set(Array(a.prefix(3)), forKey: sessionStartsKey)
    }

    static func resetPipSessionStarts() {
        UserDefaults.standard.set([Date().timeIntervalSince1970], forKey: sessionStartsKey)
    }

    /// 老版本升级上来从没记过轮次：把当前这批整体当作本次，否则首次打开一条标签都不显示。
    static func ensureSessionBaseline() {
        guard pipSessionStarts().isEmpty else { return }
        let oldest = allItems().map { $0.ts }.min() ?? Date().timeIntervalSince1970
        UserDefaults.standard.set([oldest - 1], forKey: sessionStartsKey)
    }

    // MARK: - 状态标志

    static var isBlocked: Bool {
        get { UserDefaults.standard.bool(forKey: "ns.blocked") }
        set { UserDefaults.standard.set(newValue, forKey: "ns.blocked") }
    }

    static var isWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "ns.want") }
        set { UserDefaults.standard.set(newValue, forKey: "ns.want") }
    }

    // MARK: - 返回来源 App（无键盘后：只能靠用户在设置里选默认返回 App）

    struct ReturnChoice: Identifiable, Hashable {
        let name: String
        let scheme: String
        var id: String { scheme }
    }

    /// 存的是 URL 协议串（如 "weixin://"）；"auto"＝交给系统识别，"none"＝不自动返回。
    static let returnChoices: [ReturnChoice] = [
        ReturnChoice(name: "自动识别（推荐）", scheme: "auto"),
        ReturnChoice(name: "微信", scheme: "weixin://"),
        ReturnChoice(name: "抖音", scheme: "snssdk1128://"),
        ReturnChoice(name: "QQ", scheme: "mqq://"),
        ReturnChoice(name: "小红书", scheme: "xhsdiscover://"),
        ReturnChoice(name: "微博", scheme: "sinaweibo://"),
        ReturnChoice(name: "支付宝", scheme: "alipay://"),
        ReturnChoice(name: "淘宝", scheme: "taobao://"),
        ReturnChoice(name: "短信", scheme: "sms://"),
        ReturnChoice(name: "备忘录", scheme: "mobilenotes://"),
        ReturnChoice(name: "不自动返回", scheme: "none")
    ]

    static func setDefaultReturn(_ scheme: String) {
        UserDefaults.standard.set(scheme, forKey: "ns.defaultReturn")
    }

    static func defaultReturn() -> String? {
        let s = UserDefaults.standard.string(forKey: "ns.defaultReturn") ?? ""
        return s.isEmpty ? nil : s
    }

    /// "auto" / "none" / 未设置都返回 nil（交给识别或保持不跳）。
    static func defaultReturnBundleId() -> String? {
        guard let s = defaultReturn(), s != "auto", s != "none" else { return nil }
        return s
    }

    // MARK: - 两端（主 App 内）共用的小开关

    static func moveUsedToTopOn() -> Bool {
        // 默认开；没写过这个键时返回 true。
        if UserDefaults.standard.object(forKey: "ns.moveUsedToTop") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ns.moveUsedToTop")
    }

    static func setMoveUsedToTop(_ b: Bool) {
        UserDefaults.standard.set(b, forKey: "ns.moveUsedToTop")
    }

    static func copyHapticOn() -> Bool {
        if UserDefaults.standard.object(forKey: "ns.copyHaptic") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ns.copyHaptic")
    }

    static func setCopyHaptic(_ b: Bool) {
        UserDefaults.standard.set(b, forKey: "ns.copyHaptic")
    }
}
