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
        set { store.set(Array(newValue.prefix(30)), forKey: "qp.clips") }
    }

    var pinned: [String] {
        get { store.stringArray(forKey: "qp.pinned") ?? [] }
        set { store.set(newValue, forKey: "qp.pinned") }
    }

    @discardableResult
    mutating func capture(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        var history = clips
        if history.first == text { return false }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        clips = history
        return true
    }

    func items(for tab: String) -> [String] {
        let all = tab == "clip" ? clips : phrases
        return pinned.filter { all.contains($0) } + all.filter { !pinned.contains($0) }
    }

    mutating func remove(_ text: String, from tab: String) {
        if tab == "clip" { clips = clips.filter { $0 != text } }
        else { phrases = phrases.filter { $0 != text } }
        pinned = pinned.filter { $0 != text }
    }

    mutating func togglePin(_ text: String) {
        if let i = pinned.firstIndex(of: text) { pinned.remove(at: i) }
        else { pinned.append(text) }
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
