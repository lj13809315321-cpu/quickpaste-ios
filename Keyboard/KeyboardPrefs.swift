import Foundation
import UIKit

/// 键盘扩展的全部状态。刻意只存在键盘自己的 UserDefaults 里，
/// 不依赖 App Groups / entitlement —— 爱思免费 7 天签名最容易过。
///
/// 电脑地址通过「主 App 复制到剪贴板 → 键盘读取」传递（键盘本来就需要
/// 完全访问才能联网和读剪贴板），因此零 entitlement 也能完成配置。
struct KeyboardPrefs {

    static let defaultURL = "http://192.168.1.2:8787"

    private let store = UserDefaults.standard

    static func normalize(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { u = defaultURL }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    // MARK: - 局域网同步

    var syncURL: String {
        get { KeyboardPrefs.normalize(store.string(forKey: "qp.syncURL") ?? Self.defaultURL) }
        set { store.set(KeyboardPrefs.normalize(newValue), forKey: "qp.syncURL") }
    }

    var syncPair: String {
        get { store.string(forKey: "qp.syncPair") ?? "" }
        set { store.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        forKey: "qp.syncPair") }
    }

    var syncAuto: Bool {
        get { (store.object(forKey: "qp.syncAuto") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.syncAuto") }
    }

    /// 主 App 把地址写进系统剪贴板，键盘出现时自动采用（仅在完全访问开启时可读）。
    /// 返回是否发生了变更。
    @discardableResult
    mutating func adoptPasteboardURL() -> Bool {
        guard let raw = UIPasteboard.general.string else { return false }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http://") || s.hasPrefix("https://"),
              s.contains(":8787") || s.contains(":8") else { return false }
        let n = KeyboardPrefs.normalize(s)
        if n == syncURL { return false }
        syncURL = n
        return true
    }

    // MARK: - 布局

    var columns: Int {
        get { clamp(store.object(forKey: "qp.columns") as? Int ?? 1, 1, 2) }
        set { store.set(clamp(newValue, 1, 2), forKey: "qp.columns") }
    }

    var height: CGFloat {
        get { CGFloat(clamp(store.object(forKey: "qp.height") as? Int ?? 300, 240, 360)) }
        set { store.set(clamp(Int(newValue), 240, 360), forKey: "qp.height") }
    }

    var spaceCursor: Bool {
        get { (store.object(forKey: "qp.spaceCursor") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.spaceCursor") }
    }

    var autoCollapse: Bool {
        get { (store.object(forKey: "qp.autoCollapse") as? Bool) ?? false }
        set { store.set(newValue, forKey: "qp.autoCollapse") }
    }

    // MARK: - v1.6 设置详情（与 HTML 原型 state.toggles 一一对应）

    /// 悬浮窗关闭按钮
    var floatClose: Bool {
        get { (store.object(forKey: "qp.floatClose") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.floatClose") }
    }
    /// 点击直接切换剪贴板／常用语，不再弹选择列表
    var directSwitch: Bool {
        get { (store.object(forKey: "qp.directSwitch") as? Bool) ?? false }
        set { store.set(newValue, forKey: "qp.directSwitch") }
    }
    /// 显示「新内容已保存」提示
    var savedTip: Bool {
        get { (store.object(forKey: "qp.savedTip") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.savedTip") }
    }
    /// 显示清空按钮
    var clearBtn: Bool {
        get { (store.object(forKey: "qp.clearBtn") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.clearBtn") }
    }
    /// 连续复制（呼出键盘时自动抓取系统剪贴板新内容）
    var continuous: Bool {
        get { (store.object(forKey: "qp.continuous") as? Bool) ?? false }
        set { store.set(newValue, forKey: "qp.continuous") }
    }
    /// 仅看未分类
    var onlyUnsorted: Bool {
        get { (store.object(forKey: "qp.onlyUnsorted") as? Bool) ?? false }
        set { store.set(newValue, forKey: "qp.onlyUnsorted") }
    }
    /// 工具条按钮对齐：left / center / right
    var align: String {
        get { store.string(forKey: "qp.align") ?? "left" }
        set { store.set(newValue, forKey: "qp.align") }
    }
    /// 连续复制存储位置
    var storage: String {
        get { store.string(forKey: "qp.storage") ?? "剪贴板历史" }
        set { store.set(newValue, forKey: "qp.storage") }
    }
    /// 历史保留天数；0 = 永久保留
    var historyDays: Int {
        get { clamp(store.object(forKey: "qp.historyDays") as? Int ?? 30, 0, 365) }
        set { store.set(clamp(newValue, 0, 365), forKey: "qp.historyDays") }
    }

    // MARK: - 内容

    var tab: String {
        get { store.string(forKey: "qp.tab") ?? "clip" }
        set { store.set(newValue, forKey: "qp.tab") }
    }

    var symbols: [String] {
        get {
            let saved = store.stringArray(forKey: "qp.symbols")
            return (saved?.isEmpty == false) ? saved! : ["。", "，", "？", "！", "："]
        }
        set { store.set(newValue, forKey: "qp.symbols") }
    }

    var symbolCount: Int {
        get { clamp(store.object(forKey: "qp.symbolCount") as? Int ?? 4, 2, 5) }
        set { store.set(clamp(newValue, 2, 5), forKey: "qp.symbolCount") }
    }

    var phrases: [String] {
        get {
            let saved = store.stringArray(forKey: "qp.phrases")
            return (saved?.isEmpty == false) ? saved!
                : ["好的，收到", "稍后回复你", "谢谢！", "地址：", "明天上午方便吗"]
        }
        set { store.set(newValue, forKey: "qp.phrases") }
    }

    var clips: [String] {
        get { store.stringArray(forKey: "qp.clips") ?? [] }
        set { store.set(Array(newValue.prefix(100)), forKey: "qp.clips") }
    }

    /// 与 clips 一一对应的时间戳（秒），用于「历史保留时间」自动清理
    var clipTimes: [Double] {
        get { store.array(forKey: "qp.clipTimes") as? [Double] ?? [] }
        set { store.set(newValue, forKey: "qp.clipTimes") }
    }

    var pinned: [String] {
        get { store.stringArray(forKey: "qp.pinned") ?? [] }
        set { store.set(newValue, forKey: "qp.pinned") }
    }

    /// 最近删除，可在「最近删除」页恢复
    var recentDeleted: [String] {
        get { store.stringArray(forKey: "qp.recentDeleted") ?? [] }
        set { store.set(Array(newValue.prefix(30)), forKey: "qp.recentDeleted") }
    }

    /// 按历史保留天数清理过期记录（置顶不受影响）；返回清理条数
    @discardableResult
    mutating func pruneHistory() -> Int {
        let days = historyDays
        guard days > 0 else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        var texts = clips, times = clipTimes
        // 时间数组长度不足时按「现在」补齐，避免误删旧数据
        while times.count < texts.count { times.append(Date().timeIntervalSince1970) }
        var keptTexts: [String] = [], keptTimes: [Double] = []
        for (i, t) in texts.enumerated() {
            if pinned.contains(t) || times[i] >= cutoff {
                keptTexts.append(t); keptTimes.append(times[i])
            }
        }
        let removed = texts.count - keptTexts.count
        if removed > 0 { clips = keptTexts; clipTimes = keptTimes }
        return removed
    }

    @discardableResult
    mutating func capture(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        var history = clips, times = clipTimes
        while times.count < history.count { times.append(Date().timeIntervalSince1970) }
        if history.first == text { return false }
        if let dup = history.firstIndex(of: text) {
            history.remove(at: dup); times.remove(at: dup)
        }
        history.insert(text, at: 0)
        times.insert(Date().timeIntervalSince1970, at: 0)
        clips = history; clipTimes = times
        return true
    }

    func items(for tab: String) -> [String] {
        let all = tab == "clip" ? clips : phrases
        let ordered = pinned.filter { all.contains($0) } + all.filter { !pinned.contains($0) }
        // 原型「仅看未分类」：在键盘里等价于只看未置顶（未归入常用分类）的条目
        return onlyUnsorted ? ordered.filter { !pinned.contains($0) } : ordered
    }

    mutating func remove(_ text: String, from tab: String) {
        if tab == "clip" {
            var times = clipTimes
            if let i = clips.firstIndex(of: text), i < times.count { times.remove(at: i) }
            clipTimes = times
            clips = clips.filter { $0 != text }
        } else { phrases = phrases.filter { $0 != text } }
        pinned = pinned.filter { $0 != text }
        var deleted = recentDeleted
        deleted.removeAll { $0 == text }
        deleted.insert(text, at: 0)
        recentDeleted = deleted
    }

    mutating func restore(_ text: String) {
        recentDeleted = recentDeleted.filter { $0 != text }
        var history = clips, times = clipTimes
        while times.count < history.count { times.append(Date().timeIntervalSince1970) }
        history.insert(text, at: 0)
        times.insert(Date().timeIntervalSince1970, at: 0)
        clips = history; clipTimes = times
    }

    mutating func togglePin(_ text: String) {
        if let i = pinned.firstIndex(of: text) { pinned.remove(at: i) }
        else { pinned.append(text) }
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
