import Foundation
import UIKit

/// 主 App（系统画中画 PiP 后台监听）↔ 键盘扩展 之间的「连续复制」数据通道。
///
/// 定位：这是**可选增强**。键盘自己在可见期间就能按 changeCount 抓剪贴板，
/// 真正的连续复制靠它；画中画只是让 App 在键盘收起后还能活着，多抓几条。
/// 因此这条通道不可靠时，键盘功能不受影响（v1.10 起按钮状态不再读它）。
///
/// 两级通道，按签名环境自动选择，不需要额外 entitlement：
///   1. App Group 共享容器 —— 若手机端签名工具给主 App 和键盘扩展都开了
///      group.app.mulberry6323.twilight7904，读写共享 JSON，最干净。
///   2. 系统剪贴板里的一个自定义类型 —— 零 entitlement 的兜底。
///      ⚠️ 关键约束：只能**合并进已有的那一个 item**，不能追加成第二个 item。
///      剪贴板一旦变成多 item，`UIPasteboard.string` 就读不到正文了，
///      上一版「小窗显示连续复制中、实际抓不到内容」就是这个原因。
enum QPSharedHistory {

    struct Payload: Codable {
        var items: [String] = []
        /// 每条对应的收录时刻（秒级，与 items 一一对齐）。
        /// 用可选类型：旧版本写下的 JSON 没有这个字段，要能照常解码，不能丢历史。
        /// ⚠️ 曾经这里是「读的时候拿 now 现算」，结果这几条永远被算成刚刚复制、
        /// 永远顶在列表最前面 —— 电脑同步过来的新条目永远上不去。
        var times: [Double]? = nil
        var pip: Bool = false
        /// 后台读剪贴板被系统拦了（没有「从其他 App 粘贴 → 允许」）。
        /// 用可选类型，保证旧版本写下的 JSON 还能解码，不会丢历史。
        var blocked: Bool? = nil
        /// 键盘那边请求「下次打开 App 就自动开连续复制」
        var want: Bool? = nil
        /// 主 App 后台心跳（秒级时间戳）。键盘用它判断小窗其实是不是已经死了。
        var beatAt: Double? = nil
        /// v1.8.15「连接电脑」总开关的**唯一权威状态**（true = 断开连接）。
        /// 主 App 与键盘的 UserDefaults 互不相通，两端开关都读写这一个字段，
        /// 谁改了另一端下次出现时跟随 —— 用户要求：本来就是一个功能。
        /// 用可选类型，保证旧版本写下的 JSON 还能解码，不会丢历史。
        var syncOff: Bool? = nil
        /// 最后改 syncOff 的时间戳（秒）。**关键修复**：没有 App Group 时，
        /// 共享状态靠剪贴板自定义类型兜底，而普通复制会把该类型冲掉、状态回弹
        /// （表现就是「开关关不掉、两端不同步」）。加时间戳后，每个进程各自缓存
        /// 最后一次认定的值，只在剪贴板带来「更新的」值时才更新，普通复制冲掉
        /// 自定义类型也不会让开关回弹。
        var syncOffAt: Double? = nil

        var isBlocked: Bool { blocked == true }
        var isWanted: Bool { want == true }
        var isSyncOff: Bool { syncOff == true }

        /// 第 index 条的收录时刻（毫秒）。旧版本写的 / 剪贴板兜底通道没有时间戳 → nil
        func timeMS(at index: Int) -> Double? {
            guard let t = times, index >= 0, index < t.count else { return nil }
            let v = t[index]
            return v > 0 ? v * 1000 : nil
        }

        /// 心跳还活着吗（25 秒内算活）。
        /// 没有 App Group 时写不了心跳（剪贴板兜底通道每写一次都会改
        /// changeCount），这时只认 pip 标记，不然 20 秒后就误判「小窗死了」。
        var isAlive: Bool {
            guard pip else { return false }
            guard let b = beatAt, b > 0 else { return true }
            return Date().timeIntervalSince1970 - b < 25
        }
    }

    static let groupID = "group.app.mulberry6323.twilight7904"
    private static let pbType = "app.mulberry6323.qp.capture"
    private static let fileName = "qp-shared-history.json"
    private static let maxItems = 30

    /// 没有 App Group 时是否允许用系统剪贴板兜底。
    /// 关闭后完全不动用户剪贴板（画中画抓到的东西键盘读不到，但绝不污染剪贴板）。
    static var pasteboardFallbackEnabled = true

    // MARK: - 读（主 App 与键盘扩展都会调）

    /// 本进程内的最后一份已知状态。
    /// 为什么需要：剪贴板兜底通道在 iOS 16 上可能读不到（后台 / 没授权），
    /// 如果每次 append 都从「读不到」开始，历史会被自己一条条冲掉 ——
    /// 表现就是「永远只有一条」。有了内存兜底，App 手里的记录不会丢。
    private static var memory: Payload?

    /// 只有主 App 打开它：App 是唯一写入方，读不到时用自己手里的记录继续累积，
    /// 免得「读不到 → 从空开始 → 又写回去」，历史被一条条冲掉。
    /// 键盘**不**用内存兜底：读不到共享通道就说明 App 没在写，状态应当如实显示成「没在抓」。
    static var memoryFallback = false

    static func read() -> Payload {
        if let p = readGroup() { memory = p; return p }
        if let p = readPasteboard() { memory = p; return p }
        if memoryFallback, let m = memory { return m }
        return Payload()
    }

    // ★ v1.8.12 卡顿修复：read() 在键盘侧被 0.5 秒轮询、每次点按、每次
    //   refreshList 各调一遍，之前每遍都是「读整个文件 + JSONDecoder 全量解码」
    //   （文件几十 KB 时主线程一次几毫秒，高频调用累积成可感知卡顿）。
    //   主 App 是唯一写入方且每次写必改 mtime —— 用 mtime+size 做键缓存，
    //   文件没变直接返回内存里的上一份，只有真变了才重新读盘解码。
    private static var cachedPayload: Payload?
    private static var cachedMtime: Double = -1
    private static var cachedSize: Int64 = -1

    private static func readGroup() -> Payload? {
        guard let url = groupURL() else { return nil }
        let fileURL = url.appendingPathComponent(fileName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let a = attrs,
           let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970,
           let s = (a[.size] as? NSNumber)?.int64Value,
           m == cachedMtime, s == cachedSize, let p = cachedPayload {
            return p
        }
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        cachedPayload = p
        if let a = attrs,
           let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 {
            cachedMtime = m
            cachedSize = (a[.size] as? NSNumber)?.int64Value ?? -1
        }
        return p
    }

    /// 只取我们自己的那个自定义类型，不遍历 items、不碰正文，
    /// 既快也不会因为含图片而触发粘贴授权。
    private static func readPasteboard() -> Payload? {
        guard groupURL() == nil, pasteboardFallbackEnabled else { return nil }
        guard let data = UIPasteboard.general.data(forPasteboardType: pbType) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - 写（主 App 的 PiP 管理器；setWant 由键盘调用）

    /// 收录一条新复制的文本。
    /// 注意：**内容没变就绝不写通道** —— 剪贴板兜底通道每写一次都会改
    /// changeCount，写了又读到变化，就会 0.4 秒一圈无限循环。
    @discardableResult
    static func append(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var p = read()
        var changed = false
        if p.items.first != text {
            let now = Date().timeIntervalSince1970
            // 时间戳要和 items 一一对齐：旧版本没写 times（nil）时按列表顺序补一组
            // **固定**的递减值（越靠前越新，按分钟级往回排），只补这一次，之后一直用这份。
            var times = p.times ?? []
            if times.count > p.items.count { times = Array(times.prefix(p.items.count)) }
            for i in times.count..<p.items.count {
                times.append(now - Double(i + 1) * 60)
            }
            // 去重时条目和时间戳要一起删，否则整条时间线全部错位
            var keptItems: [String] = []
            var keptTimes: [Double] = []
            for (i, s) in p.items.enumerated() where s != text {
                keptItems.append(s)
                keptTimes.append(times[i])
            }
            keptItems.insert(text, at: 0)
            keptTimes.insert(now, at: 0)
            if keptItems.count > maxItems {
                keptItems = Array(keptItems.prefix(maxItems))
                keptTimes = Array(keptTimes.prefix(maxItems))
            }
            p.items = keptItems
            p.times = keptTimes
            changed = true
        }
        // pip 保持原值：画中画是否在跑由 setPip 决定，不在这里改
        if p.isBlocked { p.blocked = false; changed = true }
        guard changed else { return false }
        // 心跳只写在 App Group 文件里；剪贴板通道不能拿来当心跳
        if groupURL() != nil { p.beatAt = Date().timeIntervalSince1970 }
        write(p, keeping: text)
        return true
    }

    static func setPip(_ on: Bool) {
        var p = read()
        guard p.pip != on else { return }
        p.pip = on
        if on, groupURL() != nil { p.beatAt = Date().timeIntervalSince1970 }
        write(p, keeping: nil)
    }

    /// 后台读剪贴板被系统拦了。只有 App Group 才写得进去 ——
    /// 剪贴板兜底通道要靠「保留正文」才能写，而被拦时根本读不到正文，
    /// 宁可不写，也不能把用户剪贴板冲掉。
    static func setBlocked(_ on: Bool) {
        guard groupURL() != nil else { return }
        var p = read()
        guard p.isBlocked != on else { return }
        p.blocked = on
        write(p, keeping: nil)
    }

    /// 键盘请求「下次打开 App 自动开启连续复制」（键盘有完全访问，读得到正文）
    static func setWant(_ on: Bool) {
        var p = read()
        guard p.isWanted != on else { return }
        p.want = on
        write(p, keeping: nil)
    }

    // MARK: 「连接电脑」总开关 —— 本地缓存 + 时间戳跟随（v1.8.15 修复）

    /// 每进程各自缓存最后一次认定的 syncOff。没有 App Group 时，共享状态靠剪贴板兜底，
    /// 普通复制会把自定义类型冲掉；缓存让「关掉后不被冲掉回弹」，且只在剪贴板带来
    /// 「更新的」值时才更新，实现两端互相跟随。
    private static var _localSyncOff = false
    private static var _localSyncOffAt: Double = 0
    private static var _syncInit = false
    private static let udSyncOff = "qp.syncOff"
    private static let udSyncOffAt = "qp.syncOffAt"

    private static func ensureSyncInit() {
        if _syncInit { return }
        _syncInit = true
        _localSyncOff = UserDefaults.standard.bool(forKey: udSyncOff)
        _localSyncOffAt = UserDefaults.standard.double(forKey: udSyncOffAt)
    }

    /// 读「连接电脑」是否断开（true = 断开）。优先认共享通道里**更新**的值，否则用本地缓存。
    static func syncOff() -> Bool {
        ensureSyncInit()
        var p: Payload?
        if let g = readGroup() { p = g }
        else if let pb = readPasteboard() { p = pb }
        if let p = p, let off = p.syncOff, let at = p.syncOffAt, at > _localSyncOffAt {
            _localSyncOff = off
            _localSyncOffAt = at
            UserDefaults.standard.set(off, forKey: udSyncOff)
            UserDefaults.standard.set(at, forKey: udSyncOffAt)
        }
        return _localSyncOff
    }

    /// v1.8.15「连接电脑」总开关（两端共用，唯一权威状态）。
    /// 主 App 设置页与键盘快捷菜单/设置页都调这里：写共享通道 + 立即更新本地缓存，
    /// 本进程立刻生效；另一端下次读共享通道（且时间戳更新）即跟随。
    @discardableResult
    static func setSyncOff(_ on: Bool) -> Bool {
        ensureSyncInit()
        var p = read()
        p.syncOff = on
        p.syncOffAt = Date().timeIntervalSince1970
        _localSyncOff = on
        _localSyncOffAt = p.syncOffAt ?? 0
        UserDefaults.standard.set(on, forKey: udSyncOff)
        UserDefaults.standard.set(_localSyncOffAt, forKey: udSyncOffAt)
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    /// 后台心跳。只有拿得到 App Group 文件时才写。
    static func beat() {
        guard groupURL() != nil else { return }
        var p = read()
        p.beatAt = Date().timeIntervalSince1970
        write(p, keeping: nil)
    }

    /// 清空共享记录。没有 App Group 时**不写系统剪贴板**：
    /// 写一次就会改 changeCount，反而会让键盘把刚清掉的内容又当成「新复制」抓回来。
    static func clear() {
        guard groupURL() != nil else { return }
        var p = read()
        guard !p.items.isEmpty else { return }
        p.items = []
        p.times = []
        write(p, keeping: nil)
    }

    /// - Parameter keeping: 已知的剪贴板正文。传了就不再去读剪贴板
    ///   （iOS 16 读正文会弹授权框，后台直接拿不到）。
    private static func write(_ p: Payload, keeping text: String?) {
        memory = p
        guard let data = try? JSONEncoder().encode(p) else { return }
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(fileName), options: .atomic)
            return
        }
        guard pasteboardFallbackEnabled else { return }
        writePasteboard(data, text: text)
    }

    /// ⚠️ 两个坑必须同时避开：
    /// 1) **不能读 `pb.items`**：iOS 16 读它就是一次「粘贴」访问，会弹授权框，
    ///    后台还会返回空数组 —— 旧实现拿到空数组后走 `pb.items = [[pbType: data]]`，
    ///    直接把用户剪贴板里的正文冲掉，等于把用户复制的东西弄丢。
    /// 2) 必须保持「单 item」：剪贴板一旦多 item，`UIPasteboard.string` 就读不到了。
    /// 所以这里只用「已经拿到的正文」+ 我们的自定义 key 拼成一条写回去。
    private static func writePasteboard(_ data: Data, text: String?) {
        let pb = UIPasteboard.general
        guard let body = text ?? pb.string, !body.isEmpty else { return }
        pb.items = [["public.utf8-plain-text": body,
                     "public.text": body,
                     pbType: data]]
    }

    private static func groupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}
