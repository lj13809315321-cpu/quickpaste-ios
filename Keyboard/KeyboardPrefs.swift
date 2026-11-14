import Foundation
import UIKit

/// 键盘扩展的全部状态。主要存在键盘自己的 UserDefaults 里，
/// 不硬性依赖 App Groups / entitlement —— 手机端签名最容易过。
/// 画中画的跨 App 历史走 Shared/QPSharedHistory.swift，按签名环境自动选通道。
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

    /// v1.8.14：「连接电脑」总开关改为两端共用共享通道字段（QPSharedHistory.syncOff），
    /// 不再放本地偏好 —— 主 App 与键盘的 UserDefaults 互不相通，本地键会造成
    /// 「App 端关了、键盘还在连」的两张皮，用户明确要求合并成一个功能。

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

    /// 复制后自动推送到电脑（默认开）。用户要求：手机复制完，电脑那边就该有，
    /// 不用再手动点「发送到电脑」。
    var autoPush: Bool {
        get { (store.object(forKey: "qp.autoPush") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.autoPush") }
    }

    var spaceCursor: Bool {
        get { (store.object(forKey: "qp.spaceCursor") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.spaceCursor") }
    }

    /// 按键震动（v1.8.6 扩展为全局）：按下任意按钮轻震一下；
    /// 空格滑光标每移动一格也会震。默认开，可在键盘设置里关
    var cursorHaptic: Bool {
        get { (store.object(forKey: "qp.cursorHaptic") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.cursorHaptic") }
    }

    /// 剪贴板类型筛选（v1.8.8 工具条漏斗按钮）：all / text / link / image / file
    var clipFilter: String {
        get { store.string(forKey: "qp.clipFilter") ?? "all" }
        set { store.set(newValue, forKey: "qp.clipFilter") }
    }

    /// 列表排序方向（v1.8.8 工具条排序按钮）：true = 最新在上（↑，默认，
    /// 与历史行为一致）；false = 最旧在上（↓）。
    var sortNewestTop: Bool {
        get { (store.object(forKey: "qp.sortNewestTop") as? Bool) ?? true }
        set { store.set(newValue, forKey: "qp.sortNewestTop") }
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

    /// v1.8.22：最后采用的「共享快捷符号设置」时间戳。
    /// 主 App 的快捷符号页改了会写共享通道；键盘只在时间戳更新时采用一次，
    /// 之后键盘内自己改的符号不会被 App 的旧值反复盖回去。
    var symbolsAt: Double {
        get { store.double(forKey: "qp.symbolsAt") }
        set { store.set(newValue, forKey: "qp.symbolsAt") }
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

    // MARK: - 时间戳（排序用）

    /// 老数据（升级前留下的）没有时间戳：按列表顺序补一次并**落盘**。
    /// ⚠️ 不能在渲染时每次都拿 `now` 现算 —— 那样这些条每一轮都被算成「刚刚复制」，
    /// 永远顶在最前面，电脑同步过来的新条目永远排不上去（这就是用户看到的排序坏掉）。
    mutating func backfillClipTimes() {
        let texts = clips
        var times = clipTimes
        guard times.count < texts.count else {
            if times.count > texts.count { clipTimes = Array(times.prefix(texts.count)) }
            return
        }
        let now = Date().timeIntervalSince1970
        for i in times.count..<texts.count { times.append(now - Double(i + 1) * 0.5) }
        clipTimes = times
    }

    /// 共享通道（连续复制 / 画中画）里没有时间戳的条目：用「首次见到的时刻」并永久固定。
    /// 有真实时间戳（新版写进 Payload.times）时不会走到这里。
    /// 间距按分钟级往回排：升级后第一次渲染时这些老条目不会一股脑挤到最前面。
    mutating func stickyTime(for text: String, index: Int) -> Double {
        var map = (store.dictionary(forKey: "qp.sharedSeen") as? [String: Double]) ?? [:]
        let key = KeyboardPrefs.stableKey(text)
        if let t = map[key] { return t * 1000 }
        let now = Date().timeIntervalSince1970 - Double(index + 1) * 60
        map[key] = now
        if map.count > 400 {
            // 别让 UserDefaults 无限长：只留最新的 240 条
            let keep = map.sorted { $0.value > $1.value }.prefix(240)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        store.set(map, forKey: "qp.sharedSeen")
        return now * 1000
    }

    /// 清空时把共享通道那几条的时间戳抹成 0，让清空闸门（clearedAt）把它们挡住。
    /// 没开 App Group 时 `QPSharedHistory.clear()` 是清不掉文件的，只能从这里下手。
    mutating func suppressShared(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        var map = (store.dictionary(forKey: "qp.sharedSeen") as? [String: Double]) ?? [:]
        for t in texts { map[KeyboardPrefs.stableKey(t)] = 0 }
        store.set(map, forKey: "qp.sharedSeen")
    }

    /// Swift 的 hashValue 每次启动都不一样，不能拿来当持久 key，这里用 FNV-1a。
    private static func stableKey(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return String(h, radix: 16)
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

    // MARK: - 删除墓碑（修复「最后一条删不掉」）

    /// 用户主动删掉 / 清空的内容。系统剪贴板里还留着这条时，轮询不能把它
    /// 再抓回来 —— 否则表现就是「删了又回来，最后一条永远删不掉」。
    var mutedTexts: [String] {
        get { store.stringArray(forKey: "qp.mutedTexts") ?? [] }
        set { store.set(Array(newValue.prefix(60)), forKey: "qp.mutedTexts") }
    }

    /// 记墓碑那一刻的剪贴板版本号：版本号变了说明用户又复制了新东西，墓碑全部失效。
    var muteChange: Int {
        get { store.object(forKey: "qp.muteChange") as? Int ?? -1 }
        set { store.set(newValue, forKey: "qp.muteChange") }
    }

    /// 上次已经抓过的剪贴板版本号（changeCount），持久化保存，
    /// 键盘被系统挂起后再回来也能知道「这段时间剪贴板换过」。
    var lastSeenChange: Int {
        get { store.object(forKey: "qp.lastSeenChange") as? Int ?? -1 }
        set { store.set(newValue, forKey: "qp.lastSeenChange") }
    }

    mutating func mute(_ texts: [String]) {
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        var m = mutedTexts
        for t in clean where !m.contains(t) { m.insert(t, at: 0) }
        mutedTexts = m
        muteChange = UIPasteboard.general.changeCount
    }

    func isMuted(_ text: String) -> Bool {
        mutedTexts.contains(text)
    }

    /// 剪贴板版本号变了就检查一次：如果用户把**被删掉的那条**又复制回来了，
    /// 解除它的墓碑（故意重复制应该能再进列表）。其它墓碑保持有效。
    mutating func refreshMute() {
        guard !mutedTexts.isEmpty else { return }
        let change = UIPasteboard.general.changeCount
        guard change != muteChange else { return }
        muteChange = change
        guard let s = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if mutedTexts.contains(s) {
            mutedTexts.removeAll { $0 == s }
        }
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

    /// 清空本机剪贴板历史。立即生效，不依赖任何网络请求。
    mutating func clearAllClips() {
        clips = []
        clipTimes = []
        // 记下清空时刻：比这更早的条目（电脑端历史回传、画中画旧记录）一律不再显示，
        // 否则「清空 → 3 秒后又被拉回来」，用户看到的就是「清空不好使」。
        store.set(Date().timeIntervalSince1970 * 1000, forKey: "qp.clearedAt")
    }

    /// 清空时刻（毫秒）。小于等于它的条目视为已删除。
    var clearedAt: Double {
        store.double(forKey: "qp.clearedAt")
    }

    /// v1.8.39：主 App「清空输入法前端剪贴板」指令的上次应用时间戳。
    /// 与共享通道里主 App 写的时间戳比较，只在有新请求时清一次键盘前端栏。
    var kbClearedAt: Double {
        get { store.double(forKey: "qp.kbClearedAt") }
        set { store.set(newValue, forKey: "qp.kbClearedAt") }
    }

    mutating func togglePin(_ text: String) {
        if let i = pinned.firstIndex(of: text) { pinned.remove(at: i) }
        else { pinned.append(text) }
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
