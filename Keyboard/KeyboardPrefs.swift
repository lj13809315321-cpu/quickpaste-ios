import Foundation

/// 键盘的全部本地状态。
/// 统一存在键盘扩展自己的 UserDefaults 里，不依赖应用组共享容器，
/// 这样一份通配符描述文件就能同时覆盖主应用与键盘扩展。
struct KeyboardPrefs {

    private let store = UserDefaults.standard

    // MARK: - 布局

    /// 列表列数：1 或 2
    var columns: Int {
        get { clamp(store.object(forKey: "qp.columns") as? Int ?? 1, 1, 2) }
        set { store.set(clamp(newValue, 1, 2), forKey: "qp.columns") }
    }

    /// 键盘高度（点）：200 ～ 320
    var height: CGFloat {
        get {
            let raw = store.object(forKey: "qp.height") as? Double ?? 260
            return CGFloat(clamp(Int(raw), 200, 320))
        }
        set { store.set(Double(clamp(Int(newValue), 200, 320)), forKey: "qp.height") }
    }

    // MARK: - 交互开关

    var spaceCursor: Bool {
        get { store.object(forKey: "qp.spaceCursor") as? Bool ?? true }
        set { store.set(newValue, forKey: "qp.spaceCursor") }
    }

    var continuousCopy: Bool {
        get { store.object(forKey: "qp.continuous") as? Bool ?? false }
        set { store.set(newValue, forKey: "qp.continuous") }
    }

    var autoCollapse: Bool {
        get { store.object(forKey: "qp.autoCollapse") as? Bool ?? false }
        set { store.set(newValue, forKey: "qp.autoCollapse") }
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
            return (saved?.isEmpty == false) ? saved! : ["好的，收到", "稍后回复你", "谢谢！", "地址：", "明天上午方便吗"]
        }
        set { store.set(newValue, forKey: "qp.phrases") }
    }

    var clips: [String] {
        get { store.stringArray(forKey: "qp.clips") ?? [] }
        set { store.set(Array(newValue.prefix(30)), forKey: "qp.clips") }
    }

    var pinned: [String] {
        get { store.stringArray(forKey: "qp.pinned") ?? [] }
        set { store.set(newValue, forKey: "qp.pinned") }
    }

    // MARK: - 剪贴板采集

    /// 把当前剪贴板文字记入历史；重复内容只保留最新一条。
    /// 返回是否发生了变更，供调用方决定要不要刷新列表。
    @discardableResult
    mutating func capture(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return false
        }
        var history = clips
        if history.first == text { return false }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        clips = history
        return true
    }

    /// 当前 Tab 要显示的内容：置顶项排在前面。
    func items(for tab: String) -> [String] {
        if tab == "clip" {
            let all = clips
            return pinned.filter { all.contains($0) } + all.filter { !pinned.contains($0) }
        }
        let all = phrases
        return pinned.filter { all.contains($0) } + all.filter { !pinned.contains($0) }
    }

    mutating func remove(_ text: String, from tab: String) {
        if tab == "clip" {
            clips = clips.filter { $0 != text }
        } else {
            phrases = phrases.filter { $0 != text }
        }
        pinned = pinned.filter { $0 != text }
    }

    mutating func togglePin(_ text: String) {
        if let index = pinned.firstIndex(of: text) {
            pinned.remove(at: index)
        } else {
            pinned.append(text)
        }
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
