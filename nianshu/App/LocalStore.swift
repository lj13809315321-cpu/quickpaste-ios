import Foundation
import UIKit
import CommonCrypto
import UniformTypeIdentifiers

// MARK: - 粘鼠 · 单进程本地存储
//
// 旧「墨指」用 App Group 文件 + 剪贴板自定义类型做**跨进程**通道（主 App ↔ 键盘扩展）。
// 粘鼠是**单 target、无键盘扩展**的独立 App，只有一个进程，整套跨进程通道都不需要：
//   · 历史 / 删除墓碑 / 开关 / 返回来源 App 全部用 UserDefaults + 本地 JSON 文件；
//   · 绝不用 UIPasteboard 给自己发指令（那是 v1.8.44 修的「冲掉用户剪贴板」的坑）。
//
// 这里集中实现 PiPManager / SettingsViews / NianshuIntents / PiPControlView
// 里所有原来对 QPSharedHistory 的调用，签名尽量一一对应，方便平移。

// MARK: - 统一条目模型（文本 / 图片二合一）

/// 列表与回贴都用这一个类型：文本条目带 text，图片条目带 imgName（缓存文件名）。
/// 用 id（= 存储里的原始键）做唯一标识，批量选择/删除都靠它。
struct NSItem: Identifiable, Hashable {
    let id: String
    let kind: ItemKind
    let text: String      // 文本内容；图片条目为空
    let imgName: String?  // 图片缓存文件名（Caches/ns_img 下）
    let ts: Double
    enum ItemKind: String, Codable { case text, image }

    /// 链接判定：仅文本条目、且以 http(s)/www 开头才算链接（用于筛选）。
    var isLink: Bool {
        guard kind == .text else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }
}

extension Data {
    /// 给图片算哈希，用来去重（避免回贴自身又被收录、或重复复制同一张图）。
    func sha256String() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(self.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalStore {

    // MARK: - 历史（主 App 唯一数据源）

    /// 单条：文本 + 真实收录时间戳（秒）。时间戳是「本次/上次/上上次」徽标与
    /// 「刚刚 / 3 分钟前」相对时间的基础，绝不能退化成「每次现算 now」，
    /// 否则所有条目都会显示「刚刚」（v1.8.43 的血泪教训）。
    /// kind/img 为可选，老版本只存了 t/ts 的 JSON 也能正常解码（旧数据一律当文本）。
    private struct StoredItem: Codable {
        var t: String
        var ts: Double
        var kind: String?   // "image" 或 nil（文本）
        var img: String?    // 图片缓存文件名
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
    static func allItems() -> [NSItem] {
        let marks = deletedMarks()
        var seen = Set<String>()
        var out: [NSItem] = []
        for it in loadItems().sorted(by: { $0.ts > $1.ts }) {
            let fp = fingerprint(it.t)
            guard !marks.contains(fp), !seen.contains(fp) else { continue }
            seen.insert(fp)
            let k: NSItem.ItemKind = (it.kind == "image") ? .image : .text
            let displayText = (k == .image) ? "" : it.t
            out.append(NSItem(id: it.t, kind: k, text: displayText, imgName: it.img, ts: it.ts))
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
        arr.insert(StoredItem(t: text, ts: Date().timeIntervalSince1970, kind: nil, img: nil), at: 0)
        if arr.count > 200 { arr = Array(arr.prefix(200)) }
        saveItems(arr)
        return true
    }

    // MARK: - 图片收录

    /// 图片缓存目录（App Caches 下，非持久但够用；单张上限见下）。
    static func imageCacheDir() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ns_img", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 收录一张刚复制到剪贴板的图片。
    ///  · 先按最长边 2048 缩放，避免大图撑爆内存；
    ///  · 有透明度存 PNG、否则存 JPEG(0.85)；
    ///  · 用图片数据哈希做去重键，既能挡掉「回贴自身又被收录」的回环，
    ///    也能忽略重复复制同一张图。
    /// 返回 true 表示这是新图片（计数 +1）。
    @discardableResult
    static func appendImage(_ image: UIImage) -> Bool {
        let maxSide: CGFloat = 2048
        var img = image
        if max(image.size.width, image.size.height) > maxSide {
            let scale = maxSide / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            img = UIGraphicsImageRenderer(size: newSize).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        let hasAlpha = (image.cgImage?.alphaInfo ?? .none) != .none
        guard let data = hasAlpha ? img.pngData() : img.jpegData(compressionQuality: 0.85) else {
            return false
        }
        let hash = data.sha256String()
        let key = "nsimg:" + hash
        let arr0 = loadItems()
        if arr0.first?.t == key { return false }
        let fname = hash + (hasAlpha ? ".png" : ".jpg")
        let fpath = imageCacheDir().appendingPathComponent(fname)
        try? data.write(to: fpath, options: .atomic)
        var arr = arr0
        arr.removeAll { $0.t == key }
        arr.insert(StoredItem(t: key, ts: Date().timeIntervalSince1970, kind: "image", img: fname), at: 0)
        if arr.count > 200 { arr = Array(arr.prefix(200)) }
        saveItems(arr)
        return true
    }

    /// 由缓存文件名读回 UIImage（列表缩略图 / 回贴用）。
    static func loadImage(named fname: String) -> UIImage? {
        let url = imageCacheDir().appendingPathComponent(fname)
        return UIImage(contentsOfFile: url.path)
    }


    /// 清空本地历史（不动系统剪贴板正文）。
    static func clearHistory() {
        saveItems([])
    }

    /// 批量删除：写墓碑 + 从本地历史移除。id 即存储键（文本=原文、图片=「nsimg:哈希」）。
    static func delete(_ ids: [String]) {
        var marks = deletedMarks()
        for id in ids { marks.insert(fingerprint(id)) }
        saveDeletedMarks(marks)
        let set = Set(ids)
        saveItems(loadItems().filter { !set.contains($0.t) })
        // 顺手清掉图片缓存文件
        for id in ids where id.hasPrefix("nsimg:") {
            let fname = String(id.dropFirst("nsimg:".count))
            try? FileManager.default.removeItem(at: imageCacheDir().appendingPathComponent(fname))
        }
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

    // MARK: - 本次合并（把「本次」这一轮的文字按复制先后拼成一条）
    //
    // 需求：本次复制了 4 条，希望它们逐步合并成一条完整的；再来一条链接就
    // 自动追加进去；这条单独显示，最终目的是推回系统剪贴板。
    // 设计：合并结果是【虚拟条目】——按需从历史实时拼出来，不写进历史、
    // 不占条目编号、不会被导出误伤，也不会把自己写回的内容再抓一遍。

    /// 开关：默认关。打开后连续复制页才额外显示那条「本次合并」，原列表完全不变。
    static func mergeSessionEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "ns.mergeSession")
    }

    /// 每条之间的连接方式：0 换行（默认）/ 1 空一行 / 2 空格 / 3 直接连起来。
    static func mergeSeparator(mode: Int) -> String {
        switch mode {
        case 1: return "\n\n"
        case 2: return " "
        case 3: return ""
        default: return "\n"
        }
    }

    /// 本次（当前画中画这一轮）收录的文字，按复制先后正序（旧 → 新）。
    /// 图片、空文本都不参与；没有轮次记录时退回全部文字。
    static func currentSessionTexts() -> [String] {
        let texts = allItems().filter { $0.kind == .text && !$0.text.isEmpty }
        let start = pipSessionStarts().first
        let scoped = start.map { s in texts.filter { $0.ts >= s } } ?? texts
        return scoped.sorted { $0.ts < $1.ts }.map { $0.text }
    }

    /// 最近 N 条文字，按复制先后正序；N <= 0 时等价于「本次全部」。
    static func recentTexts(_ count: Int) -> [String] {
        if count <= 0 { return currentSessionTexts() }
        let newest = Array(allItems()
            .filter { $0.kind == .text && !$0.text.isEmpty }
            .prefix(count))
        return newest.reversed().map { $0.text }
    }

    /// 纯函数拼接：给文字数组与连接方式，产出一条完整文本。
    /// 上限 10 万字，避免极端情况下把系统剪贴板撑爆。
    static func mergedText(_ texts: [String], separatorMode: Int) -> String {
        guard !texts.isEmpty else { return "" }
        let s = texts.joined(separator: mergeSeparator(mode: separatorMode))
        return s.count > 100_000 ? String(s.prefix(100_000)) : s
    }

    /// 常用入口：本次合并 / 最近 N 条合并（读当前的分隔方式设置）。
    static func mergedSessionText() -> String {
        let mode = UserDefaults.standard.integer(forKey: "ns.mergeSeparator")
        return mergedText(currentSessionTexts(), separatorMode: mode)
    }

    static func mergedRecentText(_ count: Int) -> String {
        let mode = UserDefaults.standard.integer(forKey: "ns.mergeSeparator")
        return mergedText(recentTexts(count), separatorMode: mode)
    }

    // MARK: - 两种「推回剪贴板」的方式（手动推 / 自动实时推）
    //
    // 方式 A 手动推（开关关）：什么时候推由人决定——点页面按钮，或跑
    //   「复制本次合并」「复制最近合并」快捷指令。剪贴板平时一直是最后复制的单条。
    // 方式 B 自动实时推（开关开）：停手约 1.5 秒后自动把本次合并整条写回。
    // 这个开关既能被 App 页面拨动，也能被快捷指令 / Siri / 自动化改，
    // 所以统一从下面这一个入口写，别各处直接 set，免得状态不同步。
    // 防「边复制边写回」打架的完整逻辑见 AutoPushMerge.swift。

    static let autoPushKey = "ns.autoPushMerge"
    static let autoPushModeChanged = Notification.Name("ns.autoPushMode.changed")

    /// 当前是不是「自动实时推」（true）/「手动推」（false）。
    static func autoPushMergeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: autoPushKey)
    }

    /// 切换推送方式。页面开关、快捷指令、Siri、自动化都走这里。
    /// · 开实时：顺手把「组装成单独一条」也打开（它是实时推的前提，不用记两个开关）。
    /// · 关实时：立刻作废挂起的延时写入、清掉写前核对的原文，
    ///          保证关掉之后绝不会再自动写一次；组装开关保留，手动推照样能用。
    /// · 不主动碰剪贴板：开关只改「以后怎么做」，不改写当前剪贴板内容。
    static func setAutoPushMerge(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: autoPushKey)
        if on {
            d.set(true, forKey: "ns.mergeSession")
        } else {
            AutoPushMerge.cancel()
            AutoPushMerge.setExpectedRaw(nil)
        }
        NotificationCenter.default.post(name: autoPushModeChanged, object: nil)
    }

    /// 翻转推送方式，返回翻转后的值（true = 自动实时推）。
    @discardableResult
    static func toggleAutoPushMerge() -> Bool {
        let next = !autoPushMergeEnabled()
        setAutoPushMerge(next)
        return next
    }

    /// 最近一条文字原文（给「恢复最后一次复制」用）。
    static func lastRawText() -> String? {
        recentTexts(1).last
    }

    /// 把合并结果写回系统剪贴板（页面按钮、全文页、快捷指令、自动推送共用）。
    /// 先登记指纹再写，PiP 的 0.4s 轮询会整条跳过，不会越滚越大。
    static func writeMergedToPasteboard(_ text: String) {
        AutoPushMerge.writeMerged(text)
    }

    /// 想粘单条时，把剪贴板从合并结果换回最后一次复制的原文。
    static func restoreLastRawCopyToPasteboard() {
        AutoPushMerge.restoreLastRaw()
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
