import Foundation
import UIKit

// MARK: - 实时推送：把「本次合并」自动写回系统剪贴板，且不与后台监听打架
//
// iOS 的 UIPasteboard.general 是【单槽位】：任一时刻只有一个当前内容。
// 「后台 0.4s 不停读」和「实时往回写」抢同一个槽位，硬写会出三种事：
//   ① 回环：写回去 → changeCount +1 → 轮询当成新复制 → 合并结果越滚越大；
//   ② 抢占：用户刚复制第 5 条，剪贴板立刻被改成合并结果，去粘贴粘到整坨；
//   ③ 覆盖：静默期间用户/别的 App 又改了剪贴板，旧快照写回去把新内容冲掉。
//
// 所以「实时」的定义是：连续复制期间粘鼠【绝不碰】剪贴板；停手 1.5 秒后
// 才写一次，且写前必须二次确认剪贴板仍是本轮最后一条用户原文。
// 写回的内容登记指纹，后台轮询识别后整条跳过（不消费，多次读也安全）。

enum AutoPushMerge {

    private static let fpKey = "ns.selfWrittenFP"
    private static let expectedKey = "ns.expectedRaw"
    private static let genKey = "ns.pushGen"

    /// 每次收录都把代号 +1，旧的延时任务到点后发现自己过期就自动作废。
    /// 用 UserDefaults 而不是静态可变存储属性，避免严格并发模式下的告警。
    private static var generation: Int {
        get { UserDefaults.standard.integer(forKey: genKey) }
        set { UserDefaults.standard.set(newValue, forKey: genKey) }
    }

    private static let quietSeconds: Double = 1.5

    // MARK: 自写指纹（防回环）

    /// 只存 sha256，不存全文：合并结果可能 10 万字，不能整条塞进 UserDefaults。
    static func noteFingerprint(_ text: String) {
        guard let d = text.data(using: .utf8) else { return }
        let fp = d.sha256String()
        var arr = UserDefaults.standard.stringArray(forKey: fpKey) ?? []
        arr.removeAll { $0 == fp }
        arr.insert(fp, at: 0)
        UserDefaults.standard.set(Array(arr.prefix(8)), forKey: fpKey)
    }

    /// 只判断、不消费：同一份自写内容被前台/后台多次读到都安全。
    static func isSelfWritten(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8) else { return false }
        let fp = d.sha256String()
        if (UserDefaults.standard.stringArray(forKey: fpKey) ?? []).contains(fp) { return true }
        // 兼容上一版的单值标记，读到后顺手清掉。
        if let old = UserDefaults.standard.string(forKey: "ns.selfWritten"),
           !old.isEmpty, old == text {
            UserDefaults.standard.removeObject(forKey: "ns.selfWritten")
            return true
        }
        return false
    }

    // MARK: 写前校验用的「最后一条用户原文」

    static func setExpectedRaw(_ text: String?) {
        let d = UserDefaults.standard
        if let t = text { d.set(t, forKey: expectedKey) }
        else { d.removeObject(forKey: expectedKey) }
    }

    static func expectedRaw() -> String? {
        UserDefaults.standard.string(forKey: expectedKey)
    }

    // MARK: 静默窗口（防抢占）

    static func schedule() {
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + quietSeconds) {
            guard mine == generation else { return }   // 期间又收了新内容 → 作废
            tryPush()
        }
    }

    static func cancel() { generation += 1 }

    /// 到点后真正尝试写回。任何一条不满足就放弃，绝不硬写。
    private static func tryPush() {
        guard LocalStore.autoPushMergeEnabled(),
              LocalStore.mergeSessionEnabled(),
              PiPManager.shared.isActive,
              !PiPManager.shared.isPaused else { return }
        let pb = UIPasteboard.general
        // ① 剪贴板必须仍是本轮最后一条用户原文；被谁改过都不写。
        guard let expected = expectedRaw(), pb.string == expected else { return }
        // ② 剪贴板里还带着图片时不写，避免把用户的图冲掉。
        guard !pb.hasImages else { return }
        let text = LocalStore.mergedSessionText()
        guard !text.isEmpty, pb.string != text else { return }
        // ③ 先登记指纹再写：写回后轮询识别到这是自己写的，会整条跳过。
        let count = LocalStore.currentSessionTexts().count
        writeMerged(text)
        PiPManager.shared.note("已自动把本次 \(count) 条合并推到剪贴板（停手 1.5 秒后写入）")
    }

    // MARK: 写入口（页面按钮 / 全文页 / 快捷指令 / 自动推送共用）

    /// 顺序不能反：先登记指纹，再写剪贴板；写后 changeCount +1，
    /// PiPManager.readNow 靠指纹集合整条跳过，不会形成回环。
    static func writeMerged(_ text: String) {
        guard !text.isEmpty else { return }
        noteFingerprint(text)
        UIPasteboard.general.string = text
        NianshuFeedback.copied()
    }

    /// 想粘单条时，把最后一次复制的原文放回剪贴板（同样登记指纹）。
    static func restoreLastRaw() {
        guard let raw = LocalStore.lastRawText(), !raw.isEmpty else { return }
        noteFingerprint(raw)
        UIPasteboard.general.string = raw
        NianshuFeedback.copied()
    }
}
