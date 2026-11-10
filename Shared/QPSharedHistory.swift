import Foundation
import UIKit
import ObjectiveC
import Darwin

/// 主 App（系统画中画 PiP 后台监听）↔ 键盘扩展 之间的「连续复制」数据通道。
///
/// 定位：这是**可选增强**。键盘自己在可见期间就能按 changeCount 抓剪贴板，
/// 真正的连续复制靠它；画中画只是让 App 在键盘收起后还能活着，多抓几条。
/// 因此这条通道不可靠时，键盘功能不受影响（v1.10 起按钮状态不再读它）。
///
/// 两级通道，按签名环境自动选择，不需要额外 entitlement：
///   1. App Group 共享容器 —— 若手机端签名工具给主 App 和键盘扩展都开了
///      group.app.mulberry6323.mozhi，读写共享 JSON，最干净。
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
        /// v1.8.18「断网自动暂停」开关（true = 手机没有 Wi-Fi 时自动停止同步轮询）。
        /// 与 syncOff 同一套权威/时间戳机制：App 设置页与键盘设置页共用一个状态，
        /// 谁改了另一端跟随。默认开（nil = 开）—— 断了网就不该再空转轮询浪费电。
        var netGuard: Bool? = nil
        /// 最后改 netGuard 的时间戳（秒），机制同 syncOffAt。
        var netGuardAt: Double? = nil
        /// v1.8.20「导出到电脑」开关（true = 导出文件直接发送到电脑接收文件夹；
        /// false = 手机本地模式：主 App 走系统分享、键盘把文本导出复制到剪贴板）。
        /// 与 syncOff / netGuard 同一套权威 + 时间戳机制，两端共用一个开关。
        var exportToPc: Bool? = nil
        /// 最后改 exportToPc 的时间戳（秒）。
        var exportToPcAt: Double? = nil
        /// v1.8.22「复制后移到最前」开关（true = 点一条旧记录使用后把它排到列表最前）。
        /// 系统剪贴板出现新内容本来就会置顶，这个开关管的是「用了旧条目也置顶」，
        /// 键盘与主 App 共用同一个开关，一处改另一端跟随。
        var moveUsedToTop: Bool? = nil
        var moveUsedToTopAt: Double? = nil
        /// v1.8.23「复制成功震动」开关（true = 复制成功时轻震一下做确认反馈）。
        /// 主 App（SwiftUI）与键盘（UIKit）共用这一个字段，两处设置页都能改。
        /// 默认开；可选类型保证旧版本 JSON 照常解码。
        var copyHaptic: Bool? = nil
        var copyHapticAt: Double? = nil
        /// v1.8.26：键盘请求「跳主 App 并落到连续复制 Tab」的时刻（秒）。
        /// iOS 18+ 系统可能拦掉键盘扩展的所有跳转，主 App 手动打开时读到它
        /// 就自动切到连续复制页并清除 —— 跳不成也能一键直达，且不开画中画。
        var pendingTabPip: Double? = nil
        /// v1.8.29：键盘轻点「连续复制」图标时写的一次性「开/关切换」指令。
        /// 轻点那条跳转是按 bundle id 把 App 拉到前台，URL 不一定送到主 App；
        /// App 从后台被激活时根视图 onAppear 也不会再触发 —— 所以不能靠
        /// onOpenURL 带动作，只能由共享通道带一条指令，主 App 一进前台就消费。
        /// 90 秒内有效、读到即清除；主 App 按自身 running 状态决定开还是关。
        var pendingPiPToggle: Double? = nil
        /// v1.8.22 快捷符号设置（主 App 与键盘共用一份）：符号列表 / 工具条显示几个 / 对齐。
        /// 放在这里而不是各自 UserDefaults，才能实现「App 里改了键盘立即生效」。
        var sharedSymbols: [String]? = nil
        var sharedSymbolCount: Int? = nil
        var sharedAlign: String? = nil
        var sharedSymbolsAt: Double? = nil

        var isBlocked: Bool { blocked == true }
        var isWanted: Bool { want == true }
        var isSyncOff: Bool { syncOff == true }
        /// nil 视为默认开启。
        var isNetGuardOn: Bool { netGuard != false }

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

    static let groupID = "group.app.mulberry6323.mozhi"
    private static let pbType = "app.mulberry6323.qp.capture"
    private static let fileName = "mozhi-shared-history.json"
    private static let maxItems = 30
    /// v1.8.30：独立于 Payload 的一次性「切页 + 开关」指令文件 / 剪贴板类型。
    /// ★ 不能塞进 Payload —— 主 App 的连续复制收录心跳每次都整份 write()
    ///   覆盖 Payload，键盘刚写进去的 pending 标记会被主 App 的旧副本冲掉。
    private static let pipCmdFile = "mozhi-pip-command.json"
    private static let pipCmdPBType = "app.mulberry6323.mozhi.pipcmd"
    /// v1.8.31：缓存「最近一次成功识别到的宿主 App 包名」。
    /// 点图标那一刻若三条探测都失败，还能用这份缓存自动跳回。
    private static let lastHostFile = "mozhi-last-host.json"
    private static let lastHostPBType = "app.mulberry6323.mozhi.lasthost"
    /// v1.8.32：用户设定的「默认返回 App」（存 URL 协议字符串）。
    /// iOS 26.4+ 系统不再给键盘宿主包名，这份设定是确定性的兜底。
    private static let defaultReturnFile = "mozhi-default-return.json"
    private static let defaultReturnPBType = "app.mulberry6323.mozhi.defaultreturn"

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

    /// v1.8.22「复制后移到最前」：把共享通道里已有的一条移到最前，
    /// **不覆盖用户剪贴板正文**（键盘里点卡片是「上屏」，不是「复制」，
    /// 用 append 会把用户当前剪贴板内容冲成这条文本）。
    /// 只有这一条本来就在共享历史里才写；返回 false 表示无需写通道。
    @discardableResult
    static func moveToFront(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var p = read()
        guard let i = p.items.firstIndex(of: text), i > 0 else { return false }
        var times = p.times ?? []
        let now = Date().timeIntervalSince1970
        while times.count < p.items.count { times.append(now) }
        let t = times[i]
        p.items.remove(at: i); times.remove(at: i)
        p.items.insert(text, at: 0); times.insert(max(t, now), at: 0)
        p.times = times
        write(p, keeping: UIPasteboard.general.string)
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

    // MARK: 「断网自动暂停」开关（v1.8.18）—— 机制与 syncOff 相同

    private static var _localNetGuard = true
    private static var _localNetGuardAt: Double = 0
    private static var _netInit = false
    private static let udNetGuard = "qp.netGuard"
    private static let udNetGuardAt = "qp.netGuardAt"

    private static func ensureNetInit() {
        if _netInit { return }
        _netInit = true
        if UserDefaults.standard.object(forKey: udNetGuard) != nil {
            _localNetGuard = UserDefaults.standard.bool(forKey: udNetGuard)
        }
        _localNetGuardAt = UserDefaults.standard.double(forKey: udNetGuardAt)
    }

    /// 读「断网自动暂停」是否开启。优先认共享通道里更新的值；无任何记录时默认开。
    static func netGuardOn() -> Bool {
        ensureNetInit()
        var p: Payload?
        if let g = readGroup() { p = g }
        else if let pb = readPasteboard() { p = pb }
        if let p = p, let on = p.netGuard, let at = p.netGuardAt, at > _localNetGuardAt {
            _localNetGuard = on
            _localNetGuardAt = at
            UserDefaults.standard.set(on, forKey: udNetGuard)
            UserDefaults.standard.set(at, forKey: udNetGuardAt)
        }
        return _localNetGuard
    }

    /// 写「断网自动暂停」开关：共享通道 + 本进程立即生效，另一端跟随。
    @discardableResult
    static func setNetGuard(_ on: Bool) -> Bool {
        ensureNetInit()
        var p = read()
        p.netGuard = on
        p.netGuardAt = Date().timeIntervalSince1970
        _localNetGuard = on
        _localNetGuardAt = p.netGuardAt ?? 0
        UserDefaults.standard.set(on, forKey: udNetGuard)
        UserDefaults.standard.set(_localNetGuardAt, forKey: udNetGuardAt)
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    // MARK: 「导出到电脑」开关（v1.8.20）—— 机制与 syncOff / netGuard 相同

    private static var _localExportToPc = true
    private static var _localExportToPcAt: Double = 0
    private static var _exportInit = false
    private static let udExportToPc = "qp.exportToPc"
    private static let udExportToPcAt = "qp.exportToPcAt"

    private static func ensureExportInit() {
        if _exportInit { return }
        _exportInit = true
        if UserDefaults.standard.object(forKey: udExportToPc) != nil {
            _localExportToPc = UserDefaults.standard.bool(forKey: udExportToPc)
        }
        _localExportToPcAt = UserDefaults.standard.double(forKey: udExportToPcAt)
    }

    /// 读「导出到电脑」是否开启。优先认共享通道里更新的值；无任何记录时默认开。
    static func exportToPcOn() -> Bool {
        ensureExportInit()
        var p: Payload?
        if let g = readGroup() { p = g }
        else if let pb = readPasteboard() { p = pb }
        if let p = p, let on = p.exportToPc, let at = p.exportToPcAt, at > _localExportToPcAt {
            _localExportToPc = on
            _localExportToPcAt = at
            UserDefaults.standard.set(on, forKey: udExportToPc)
            UserDefaults.standard.set(at, forKey: udExportToPcAt)
        }
        return _localExportToPc
    }

    /// 写「导出到电脑」开关：共享通道 + 本进程立即生效，另一端跟随。
    @discardableResult
    static func setExportToPc(_ on: Bool) -> Bool {
        ensureExportInit()
        var p = read()
        p.exportToPc = on
        p.exportToPcAt = Date().timeIntervalSince1970
        _localExportToPc = on
        _localExportToPcAt = p.exportToPcAt ?? 0
        UserDefaults.standard.set(on, forKey: udExportToPc)
        UserDefaults.standard.set(_localExportToPcAt, forKey: udExportToPcAt)
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    // MARK: 「复制成功震动」开关（v1.8.23）—— 机制与上面几个共用开关相同

    private static var _localCopyHaptic = true
    private static var _localCopyHapticAt: Double = 0
    private static var _copyInit = false
    private static let udCopyHaptic = "qp.copyHaptic"
    private static let udCopyHapticAt = "qp.copyHapticAt"

    private static func ensureCopyInit() {
        if _copyInit { return }
        _copyInit = true
        if UserDefaults.standard.object(forKey: udCopyHaptic) != nil {
            _localCopyHaptic = UserDefaults.standard.bool(forKey: udCopyHaptic)
        }
        _localCopyHapticAt = UserDefaults.standard.double(forKey: udCopyHapticAt)
    }

    /// 读「复制成功震动」是否开启。优先认共享通道里更新的值；无记录时默认开。
    static func copyHapticOn() -> Bool {
        ensureCopyInit()
        var p: Payload?
        if let g = readGroup() { p = g }
        else if let pb = readPasteboard() { p = pb }
        if let p = p, let on = p.copyHaptic, let at = p.copyHapticAt, at > _localCopyHapticAt {
            _localCopyHaptic = on
            _localCopyHapticAt = at
            UserDefaults.standard.set(on, forKey: udCopyHaptic)
            UserDefaults.standard.set(at, forKey: udCopyHapticAt)
        }
        return _localCopyHaptic
    }

    /// 写「复制成功震动」开关：共享通道 + 本进程立即生效，另一端跟随。
    @discardableResult
    static func setCopyHaptic(_ on: Bool) -> Bool {
        ensureCopyInit()
        var p = read()
        p.copyHaptic = on
        p.copyHapticAt = Date().timeIntervalSince1970
        _localCopyHaptic = on
        _localCopyHapticAt = p.copyHapticAt ?? 0
        UserDefaults.standard.set(on, forKey: udCopyHaptic)
        UserDefaults.standard.set(_localCopyHapticAt, forKey: udCopyHapticAt)
        write(p, keeping: UIPasteboard.general.string)
        MozhiFeedback.noteSettingChanged(on)
        return true
    }

    // MARK: v1.8.26「跳主 App 落到连续复制页」的一次性标记

    /// 键盘发起跳转时调用。写进共享通道，App Group 或剪贴板自定义类型都能带过去。
    /// 即使系统把跳转全拦了，用户手动点桌面图标进 App 也能直达目标页。
    static func markPendingTabPip() {
        var p = read()
        p.pendingTabPip = Date().timeIntervalSince1970
        write(p, keeping: UIPasteboard.general.string)
    }

    /// 主 App 出现时调用：10 分钟内的标记才生效，读到即消费，避免以后每次打开都跳页。
    static func consumePendingTabPip() -> Bool {
        var p = read()
        guard let at = p.pendingTabPip,
              Date().timeIntervalSince1970 - at < 600 else { return false }
        p.pendingTabPip = nil
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    // MARK: v1.8.29「按一下开、再按一下关」的一次性指令

    /// 键盘轻点工具条「连续复制」图标时调用，与 pendingTabPip 一起带过去。
    static func markPendingPiPToggle() {
        var p = read()
        p.pendingPiPToggle = Date().timeIntervalSince1970
        write(p, keeping: UIPasteboard.general.string)
    }

    /// 主 App 在 onOpenURL / onAppear / scenePhase 变 active 时调用。
    /// 90 秒内的指令才生效，读到即消费，保证只执行一次、不会反复开关。
    static func consumePendingPiPToggle() -> Bool {
        var p = read()
        guard let at = p.pendingPiPToggle,
              Date().timeIntervalSince1970 - at < 90 else { return false }
        p.pendingPiPToggle = nil
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    // MARK: v1.8.30 独立一次性指令 / v1.8.31 带来源 App 包名

    /// 一次性指令。v1.8.30 只写时间戳（Double），v1.8.31 起带上宿主 App 包名，
    /// 主 App 开/关连续复制后按它跳回原来的 App。
    struct PipCommand: Codable {
        var at: Double = 0
        var host: String? = nil
    }

    /// 键盘轻点工具条「连续复制」图标时调用。
    /// 走独立文件 / 独立剪贴板类型，绝不碰 Payload，也不会碰用户剪贴板正文：
    /// setData 只替换第一个 item 里的这个自定义类型，不新增 item、不动正文。
    static func markPipCommand(host: String?) {
        let cmd = PipCommand(at: Date().timeIntervalSince1970, host: host)
        guard let data = try? JSONEncoder().encode(cmd) else { return }
        // ★ 双写：两端 App Group 签名不一致时，groupURL() 可能一边有效一边无效。
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(pipCmdFile), options: .atomic)
        }
        if pasteboardFallbackEnabled {
            UIPasteboard.general.setData(data, forPasteboardType: pipCmdPBType)
        }
    }

    /// 主 App 在前台任一入口调用：90 秒内的指令生效，读到即清，只执行一次。
    /// 兼容 v1.8.30 写下的纯 Double 时间戳（那种没有来源包名，不会回跳）。
    /// ★ 常规轮询（无指令时）只读一次小文件 + 一次剪贴板自定义类型，
    ///   不落盘、不改 changeCount，不会带来卡顿。
    static func consumePipCommand() -> PipCommand? {
        let now = Date().timeIntervalSince1970
        let cmdFile = groupURL()?.appendingPathComponent(pipCmdFile)

        func valid(_ d: Data?) -> PipCommand? {
            guard let d = d else { return nil }
            if let c = try? JSONDecoder().decode(PipCommand.self, from: d),
               c.at > 0, now - c.at < 90 { return c }
            if let at = try? JSONDecoder().decode(Double.self, from: d),
               at > 0, now - at < 90 { return PipCommand(at: at, host: nil) }
            return nil
        }

        var fileData: Data? = nil
        if let f = cmdFile { fileData = try? Data(contentsOf: f) }
        let got = valid(fileData)
            ?? valid(UIPasteboard.general.data(forPasteboardType: pipCmdPBType))
        guard let cmd = got else { return nil }
        // 写「过期值 0」代替删除：删除失败时也不会重复消费导致反复开关。
        let expired = (try? JSONEncoder().encode(PipCommand(at: 0, host: nil))) ?? Data()
        if let f = cmdFile { try? expired.write(to: f, options: .atomic) }
        if pasteboardFallbackEnabled {
            UIPasteboard.general.setData(expired, forPasteboardType: pipCmdPBType)
        }
        return cmd
    }

    // MARK: v1.8.31「最近一次宿主 App 包名」缓存

    /// 键盘每次出现时探测到宿主就写进来，长期有效（不清），
    /// 点图标那一刻探测失败时用它兜底。
    static func cacheHostBundleId(_ host: String) {
        guard !host.isEmpty, let data = try? JSONEncoder().encode(host) else { return }
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(lastHostFile), options: .atomic)
        }
        if pasteboardFallbackEnabled {
            UIPasteboard.general.setData(data, forPasteboardType: lastHostPBType)
        }
    }

    static func cachedHostBundleId() -> String? {
        if let f = groupURL()?.appendingPathComponent(lastHostFile),
           let d = try? Data(contentsOf: f),
           let s = try? JSONDecoder().decode(String.self, from: d), !s.isEmpty { return s }
        guard let d = UIPasteboard.general.data(forPasteboardType: lastHostPBType),
              let s = try? JSONDecoder().decode(String.self, from: d),
              !s.isEmpty else { return nil }
        return s
    }

    // MARK: v1.8.32「默认返回 App」—— iOS 26.4+ 的确定性兜底

    struct MozhiReturnChoice: Identifiable, Hashable {
        let name: String
        let scheme: String
        var id: String { scheme }
    }

    /// 用户可选：自动识别 / 常用 App / 不自动返回。
    /// 存的是 URL 协议串（如 "weixin://"）；"auto"＝交给系统识别。
    static let returnChoices: [MozhiReturnChoice] = [
        MozhiReturnChoice(name: "自动识别（推荐）", scheme: "auto"),
        MozhiReturnChoice(name: "微信", scheme: "weixin://"),
        MozhiReturnChoice(name: "抖音", scheme: "snssdk1128://"),
        MozhiReturnChoice(name: "QQ", scheme: "mqq://"),
        MozhiReturnChoice(name: "小红书", scheme: "xhsdiscover://"),
        MozhiReturnChoice(name: "微博", scheme: "sinaweibo://"),
        MozhiReturnChoice(name: "支付宝", scheme: "alipay://"),
        MozhiReturnChoice(name: "淘宝", scheme: "taobao://"),
        MozhiReturnChoice(name: "短信", scheme: "sms://"),
        MozhiReturnChoice(name: "备忘录", scheme: "mobilenotes://"),
        MozhiReturnChoice(name: "不自动返回", scheme: "none")
    ]

    static func setDefaultReturn(_ scheme: String) {
        guard let data = try? JSONEncoder().encode(scheme) else { return }
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(defaultReturnFile), options: .atomic)
        }
        if pasteboardFallbackEnabled {
            UIPasteboard.general.setData(data, forPasteboardType: defaultReturnPBType)
        }
    }

    static func defaultReturn() -> String? {
        if let f = groupURL()?.appendingPathComponent(defaultReturnFile),
           let d = try? Data(contentsOf: f),
           let s = try? JSONDecoder().decode(String.self, from: d), !s.isEmpty { return s }
        guard let d = UIPasteboard.general.data(forPasteboardType: defaultReturnPBType),
              let s = try? JSONDecoder().decode(String.self, from: d),
              !s.isEmpty else { return nil }
        return s
    }

    /// 键盘侧用：把默认设定折成 host 字符串。
    /// "auto" / "none" / 未设置都返回 nil（交给识别或保持不跳）。
    static func defaultReturnBundleId() -> String? {
        guard let s = defaultReturn(), s != "auto", s != "none" else { return nil }
        return s
    }

    // MARK: 「复制后移到最前」开关（v1.8.22）—— 机制与上面三个共用开关相同

    private static var _localMoveUsedToTop = true
    private static var _localMoveUsedToTopAt: Double = 0
    private static var _moveInit = false
    private static let udMoveUsedToTop = "qp.moveUsedToTop"
    private static let udMoveUsedToTopAt = "qp.moveUsedToTopAt"

    private static func ensureMoveInit() {
        if _moveInit { return }
        _moveInit = true
        if UserDefaults.standard.object(forKey: udMoveUsedToTop) != nil {
            _localMoveUsedToTop = UserDefaults.standard.bool(forKey: udMoveUsedToTop)
        }
        _localMoveUsedToTopAt = UserDefaults.standard.double(forKey: udMoveUsedToTopAt)
    }

    /// 读「复制后移到最前」是否开启。默认开；共享通道里更新的值优先。
    static func moveUsedToTopOn() -> Bool {
        ensureMoveInit()
        var p: Payload?
        if let g = readGroup() { p = g }
        else if let pb = readPasteboard() { p = pb }
        if let p = p, let on = p.moveUsedToTop, let at = p.moveUsedToTopAt, at > _localMoveUsedToTopAt {
            _localMoveUsedToTop = on
            _localMoveUsedToTopAt = at
            UserDefaults.standard.set(on, forKey: udMoveUsedToTop)
            UserDefaults.standard.set(at, forKey: udMoveUsedToTopAt)
        }
        return _localMoveUsedToTop
    }

    @discardableResult
    static func setMoveUsedToTop(_ on: Bool) -> Bool {
        ensureMoveInit()
        var p = read()
        p.moveUsedToTop = on
        p.moveUsedToTopAt = Date().timeIntervalSince1970
        _localMoveUsedToTop = on
        _localMoveUsedToTopAt = p.moveUsedToTopAt ?? 0
        UserDefaults.standard.set(on, forKey: udMoveUsedToTop)
        UserDefaults.standard.set(_localMoveUsedToTopAt, forKey: udMoveUsedToTopAt)
        write(p, keeping: UIPasteboard.general.string)
        return true
    }

    // MARK: 快捷符号设置（v1.8.22，主 App 与键盘共用一份）

    /// 共享符号设置。symbols 为空 = 还没有人在 App 里设置过，键盘用自己的本地默认。
    static func sharedSymbolSettings() -> (symbols: [String], count: Int, align: String, at: Double) {
        let p = read()
        return (p.sharedSymbols ?? [],
                p.sharedSymbolCount ?? 4,
                p.sharedAlign ?? "left",
                p.sharedSymbolsAt ?? 0)
    }

    /// 写共享符号设置：App 的「快捷符号」页和键盘内「快捷符号」页都调这里。
    /// 返回写入的时间戳，调用方记下它，免得下次进页面又被自己的值「更新」一次。
    @discardableResult
    static func setSharedSymbols(_ symbols: [String], count: Int, align: String) -> Double {
        let at = Date().timeIntervalSince1970
        var p = read()
        p.sharedSymbols = symbols
        p.sharedSymbolCount = count
        p.sharedAlign = align
        p.sharedSymbolsAt = at
        write(p, keeping: UIPasteboard.general.string)
        return at
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
        // v1.8.22：剪贴板是「单 item」，以前这里整条重写会把同一个 item 里
        // 别的自定义类型（尤其是常用语通道 QPPhraseStore）冲掉。
        // 现在先留下已有 item 里的其它 key，只覆盖正文与自己的 capture 数据。
        var item: [String: Any] = [:]
        if let first = pb.items.first {
            for (k, v) in first where k != "public.utf8-plain-text" && k != "public.text" {
                item[k] = v
            }
        }
        item["public.utf8-plain-text"] = body
        item["public.text"] = body
        item[pbType] = data
        pb.items = [item]
    }

    private static func groupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// 供 QPPhraseStore 复用同一个 App Group 目录 / 剪贴板类型，避免两条通道互相冲掉。
    static func sharedGroupURL() -> URL? { groupURL() }
    static let capturePBType = pbType
}

// MARK: - 常用语独立通道（v1.8.22）

/// 为什么必须独立：单条常用语可以长达 20000 字节、最多 200 条（合计可达 4MB），
/// 而 QPSharedHistory 的 Payload 在键盘里被 0.5 秒轮询、每次新增剪贴板记录都要
/// 重新编码写入。把大列表塞进去，用户每复制一次都要编码几 MB —— 那就是「卡」。
/// 这里用**独立的 App Group 文件**（或剪贴板里独立的自定义类型），
/// 键盘只有真正点开「常用语」浮层时才读一次，平时轮询完全不碰它。
enum QPPhraseStore {
    /// 用户口径（v1.8.22）：最多 200 条常用语，**单条**可以到 20000 字节。
    /// 「一万」说的是一条里的字节数，不是条数 —— 条数严格限制 200。
    static let maxCount = 200
    static let maxItemBytes = 20000

    /// 导入/保存前统一清洗：去空行、按 UTF-8 字节安全截断超长条目、去重、限 200 条。
    static func sanitize(_ items: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in items {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            let capped = capUTF8(s)
            if seen.insert(capped).inserted { out.append(capped) }
            if out.count >= maxCount { break }
        }
        return out
    }

    /// 按 Character 边界截断到 maxItemBytes 个字节，不会切出半个汉字/半个 emoji。
    private static func capUTF8(_ s: String) -> String {
        guard s.utf8.count > maxItemBytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxItemBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// 当前列表的总字节数（App 分类页显示「用了多少 / 上限多少」）。
    static func usedBytes(_ items: [String]) -> Int {
        items.reduce(0) { $0 + $1.utf8.count }
    }
    private static let phrasePBType = "app.mulberry6323.qp.phrases"
    private static let phraseFile = "mozhi-phrases.json"

    static func read() -> [String] {
        if let url = QPSharedHistory.sharedGroupURL() {
            let f = url.appendingPathComponent(phraseFile)
            if let d = try? Data(contentsOf: f),
               let a = try? JSONDecoder().decode([String].self, from: d) { return a }
            return []
        }
        // 读自定义类型不算「读正文」，不会触发粘贴授权弹窗
        guard let d = UIPasteboard.general.data(forPasteboardType: phrasePBType),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }

    /// 主 App「分类」页保存 / 导入时调用。无 App Group 时写进剪贴板同一个 item，
    /// 保留原有正文、图片以及 capture 通道的数据，不覆盖用户剪贴板内容。
    @discardableResult
    static func write(_ items: [String]) -> Int {
        let arr = sanitize(items)
        guard let data = try? JSONEncoder().encode(arr) else { return 0 }
        if let url = QPSharedHistory.sharedGroupURL() {
            try? data.write(to: url.appendingPathComponent(phraseFile), options: .atomic)
            return arr.count
        }
        let pb = UIPasteboard.general
        var item: [String: Any] = [:]
        if let first = pb.items.first {
            for (k, v) in first { item[k] = v }
        }
        item[phrasePBType] = data
        pb.items = [item]
        return arr.count
    }
}

/// v1.8.23「复制成功」确认反馈：主 App（SwiftUI）与键盘（UIKit）共用一份实现。
/// iOS 16 只能用 UIKit 的反馈器 —— SwiftUI 的 `.sensoryFeedback` 要 iOS 17，
/// 而本工程最低部署目标是 iOS 16；键盘里的 QPHapticButton 是 UIButton 子类，
/// SwiftUI 的 Button 也走不到它，所以主 App 此前所有复制都没有触感。
/// 静态复用一个反馈器、只预热一次，点击时不分配大对象，不影响流畅度。
enum MozhiFeedback {
    private static let generator = UINotificationFeedbackGenerator()
    private static var prepared = false
    /// ★ 不卡顿：共享通道里带着整份历史 JSON，不能每点一次复制就解码一遍。
    /// 开关值在本进程缓存 2 秒；设置页一改就立刻同步缓存，不等待节流。
    private static var cachedOn = true
    private static var lastCheck: TimeInterval = 0

    /// 设置页改过开关时调用：下一次复制立即按新值执行。
    static func noteSettingChanged(_ on: Bool) {
        cachedOn = on
        lastCheck = Date().timeIntervalSince1970
    }

    /// 复制**成功**后调用（不是按下时）。节流后绝大多数调用只有一次时间比较。
    static func copied() {
        let now = Date().timeIntervalSince1970
        if now - lastCheck > 2 {
            cachedOn = QPSharedHistory.copyHapticOn()
            lastCheck = now
        }
        guard cachedOn else { return }
        if !prepared {
            prepared = true
            generator.prepare()
        }
        generator.notificationOccurred(.success)
    }
}


// MARK: - v1.8.31 宿主 App 包名解析（键盘侧调用 / 主 App 侧复用 scheme 表）

/// 尽力解析「当前键盘宿主 App」的包名，用于开启连续复制后自动跳回。
/// iOS 没有公开 API，按三条路径尝试：
///   ① 安全 ivar 扫描（不用盲试 value(forKey:)，避免 NSUnknownKeyException）
///   ② 系统工作区当前前台 App（点图标这一刻宿主仍是前台）
///   ③ 老版 _hostPID + PKService + XPC 链（iOS 16~26.3）
/// 全部失败返回 nil，调用方用「最近一次成功识别」缓存兜底。
/// 扫描深度与对象数都设了上限，只在键盘出现与点击时各跑一次，不轮询、不卡顿。
enum MozhiHostResolver {

    /// v1.8.32：arbiter 捕获值也要过一遍合法性判断（比旧三路径宽松，
    /// 因为 iOS 26.4+ 真实系统 App 也会用 com.apple.* 命名空间）。
    static func isPlausible(_ s: String) -> Bool {
        guard s.count >= 4, s.count <= 120, s.contains(".") else { return false }
        let own = Bundle.main.bundleIdentifier ?? ""
        if s == own || s.hasPrefix("app.mulberry6323") { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        let low = s.lowercased()
        if low.hasPrefix("ui") || low.hasPrefix("ns") || low.hasPrefix("_")
            || low.hasSuffix(".framework") || low.hasSuffix(".bundle")
            || low.contains("xpc") || low.contains("extension") { return false }
        return true
    }

    /// v1.8.32：包名（或已经是协议串）→ 可打开的 URL 协议。
    static func scheme(for host: String) -> String? {
        if host.contains("://") { return host }
        return knownSchemes[host]
    }

    /// 常见 App 包名 → URL 协议；按包名拉起失败时主 App 再试一次协议。
    static let knownSchemes: [String: String] = [
        "com.tencent.xin": "weixin://",                    // 微信
        "com.ss.iphone.ugc.Aweme": "snssdk1128://",        // 抖音
        "com.ss.iphone.ugc.AwemeLite": "snssdk1128://",    // 抖音极速版
        "com.tencent.mqq": "mqq://",                       // QQ
        "com.sina.weibo": "sinaweibo://",                  // 微博
        "com.apple.MobileSMS": "sms://",                   // 短信
        "com.apple.mobilenotes": "mobilenotes://",         // 备忘录
        "com.apple.mobilesafari": "https://",              // Safari
        "com.alipay.iphoneclient": "alipay://",            // 支付宝
        "com.taobao.taobao4iphone": "taobao://",           // 淘宝
        "com.xingin.discover": "xhsdiscover://",           // 小红书
        "com.zhiliaoapp.musically": "snssdk1233://"        // TikTok
    ]

    static func resolve(from vc: UIInputViewController) -> String? {
        let own = Bundle.main.bundleIdentifier ?? ""
        var roots: [AnyObject] = [vc]
        if let p = vc.parent { roots.append(p) }
        var next: UIResponder? = vc.next
        for _ in 0..<6 {
            guard let n = next else { break }
            roots.append(n)
            next = n.next
        }
        // ① 优先认 ivar 名里带 host / bundle / source / app 的包名串
        for o in roots {
            if let s = scan(o, own: own, namedOnly: true, depth: 0) { return s }
        }
        // ② 系统工作区：点图标这一刻宿主 App 仍是前台 App
        if let s = viaWorkspaceFrontmost(own: own) { return s }
        // ③ iOS 16~26.3 的 PID + XPC 链
        if let s = viaHostPID(vc: vc, own: own) { return s }
        // ④ 最后放宽：任意对象 ivar 里的第三方包名
        for o in roots {
            if let s = scan(o, own: own, namedOnly: false, depth: 0) { return s }
        }
        return nil
    }

    // MARK: 安全 ivar 扫描

    private static func scan(_ o: AnyObject, own: String, namedOnly: Bool, depth: Int) -> String? {
        guard depth < 2 else { return nil }
        var cls: AnyClass? = object_getClass(o)
        var level = 0
        var nested: [AnyObject] = []
        while let c = cls, level < 8 {
            var n: UInt32 = 0
            if let list = class_copyIvarList(c, &n) {
                for i in 0..<Int(n) {
                    let iv = list[i]
                    guard let enc = ivar_getTypeEncoding(iv),
                          String(cString: enc).hasPrefix("@") else { continue }
                    guard let raw = object_getIvar(o, iv) else { continue }
                    let name = ivar_getName(iv).map { String(cString: $0) } ?? ""
                    if let s = raw as? String, isHostBundleId(s, own: own) {
                        let low = name.lowercased()
                        let named = low.contains("host") || low.contains("bundle")
                            || low.contains("source") || low.contains("app")
                        if namedOnly == named { return s }
                    }
                    if nested.count < 10, !(raw is String), !(raw is NSNumber),
                       let obj = raw as? AnyObject { nested.append(obj) }
                }
                free(list)
            }
            cls = class_getSuperclass(c)
            level += 1
        }
        for child in nested {
            if let s = scan(child, own: own, namedOnly: namedOnly, depth: depth + 1) { return s }
        }
        return nil
    }

    // MARK: 系统工作区的前台 App

    private static func viaWorkspaceFrontmost(own: String) -> String? {
        guard let wsCls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let def = NSSelectorFromString("defaultWorkspace")
        guard wsCls.responds(to: def),
              let ws = wsCls.perform(def)?.takeUnretainedValue() as? NSObject else { return nil }
        for key in ["frontmostApplication", "activeApplication", "_frontmostApplication"] {
            let sel = NSSelectorFromString(key)
            guard ws.responds(to: sel),
                  let m = class_getInstanceMethod(object_getClass(ws), sel) else { continue }
            let ret = method_copyReturnType(m)
            let isObj = String(cString: ret).hasPrefix("@")
            free(ret)
            guard isObj,
                  let raw = ws.perform(sel)?.takeUnretainedValue() as? NSObject else { continue }
            let bSel = NSSelectorFromString("bundleIdentifier")
            guard raw.responds(to: bSel),
                  let b = raw.perform(bSel)?.takeUnretainedValue() as? String,
                  isHostBundleId(b, own: own) else { continue }
            return b
        }
        return nil
    }

    // MARK: 老版 _hostPID + PKService + XPC

    private static func viaHostPID(vc: UIInputViewController, own: String) -> String? {
        guard let parent = vc.parent as? NSObject,
              class_getInstanceVariable(object_getClass(parent), "_hostPID") != nil,
              let pid = parent.value(forKey: "_hostPID") as? NSNumber,
              let pkCls = NSClassFromString("PKService") as? NSObject.Type else { return nil }
        let def = NSSelectorFromString("defaultService")
        guard pkCls.responds(to: def),
              let svc = pkCls.perform(def)?.takeUnretainedValue() as? NSObject else { return nil }
        let perSel = NSSelectorFromString("personalities")
        guard svc.responds(to: perSel),
              let per = svc.perform(perSel)?.takeUnretainedValue() as? NSDictionary,
              let infos = per.object(forKey: own) as? NSDictionary,
              let info = infos.object(forKey: pid) as? NSObject else { return nil }
        let conSel = NSSelectorFromString("connection")
        guard info.responds(to: conSel),
              let con = info.perform(conSel)?.takeUnretainedValue() as? NSObject else { return nil }
        let xpcSel = NSSelectorFromString("_xpcConnection")
        guard con.responds(to: xpcSel),
              let xpc = con.perform(xpcSel)?.takeUnretainedValue() else { return nil }
        guard let h = dlopen("/usr/lib/libc.dylib", RTLD_NOW) else { return nil }
        defer { dlclose(h) }
        guard let sym = dlsym(h, "xpc_connection_copy_bundle_id") else { return nil }
        typealias Fn = @convention(c) (AnyObject) -> UnsafePointer<CChar>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let p = fn(xpc) else { return nil }
        let s = String(cString: p)
        return isHostBundleId(s, own: own) ? s : nil
    }

    // MARK: 判定（宁可不跳，也不乱跳到别的 App）

    private static func isHostBundleId(_ s: String, own: String) -> Bool {
        if s.isEmpty || s == own || s.hasPrefix("app.mulberry6323") { return false }
        if s.count < 5 || s.count > 100 || !s.contains(".") { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        let low = s.lowercased()
        if low.hasPrefix("ui") || low.hasPrefix("ns") || low.hasPrefix("_")
            || low.hasSuffix(".framework") || low.hasSuffix(".bundle")
            || low.contains("xpc") || low.contains("extension") { return false }
        if low.hasPrefix("com.apple.") && knownSchemes[s] == nil { return false }
        return true
    }
}
