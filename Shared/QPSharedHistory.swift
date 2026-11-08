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
        var pip: Bool = false
    }

    static let groupID = "group.app.mulberry6323.twilight7904"
    private static let pbType = "app.mulberry6323.qp.capture"
    private static let fileName = "qp-shared-history.json"
    private static let maxItems = 30

    /// 没有 App Group 时是否允许用系统剪贴板兜底。
    /// 关闭后完全不动用户剪贴板（画中画抓到的东西键盘读不到，但绝不污染剪贴板）。
    static var pasteboardFallbackEnabled = true

    // MARK: - 读（主 App 与键盘扩展都会调）

    static func read() -> Payload {
        if let p = readGroup() { return p }
        if let p = readPasteboard() { return p }
        return Payload()
    }

    private static func readGroup() -> Payload? {
        guard let url = groupURL(),
              let data = try? Data(contentsOf: url.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// 只取我们自己的那个自定义类型，不遍历 items、不碰正文，
    /// 既快也不会因为含图片而触发粘贴授权。
    private static func readPasteboard() -> Payload? {
        guard groupURL() == nil, pasteboardFallbackEnabled else { return nil }
        guard let data = UIPasteboard.general.data(forPasteboardType: pbType) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - 写（只有主 App 的 PiP 管理器调用）

    /// 收录一条新复制的文本。已是最新一条时直接返回 false，避免自己写通道
    /// 改变 changeCount 后又触发自己，形成无限循环。
    @discardableResult
    static func append(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var p = read()
        guard p.items.first != text else { return false }
        p.items.removeAll { $0 == text }
        p.items.insert(text, at: 0)
        p.items = Array(p.items.prefix(maxItems))
        write(p)
        return true
    }

    static func setPip(_ on: Bool) {
        var p = read()
        guard p.pip != on else { return }
        p.pip = on
        write(p)
    }

    /// 清空共享记录。没有 App Group 时**不写系统剪贴板**：
    /// 写一次就会改 changeCount，反而会让键盘把刚清掉的内容又当成「新复制」抓回来。
    static func clear() {
        guard groupURL() != nil else { return }
        var p = read()
        guard !p.items.isEmpty else { return }
        p.items = []
        write(p)
    }

    private static func write(_ p: Payload) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(fileName), options: .atomic)
            return
        }
        guard pasteboardFallbackEnabled else { return }
        writePasteboard(data)
    }

    /// ⚠️ 必须保持「单 item」语义：
    /// 剪贴板里只有一个 item 时，把它自己的字典拿来加一个自定义 key 再写回，
    /// `.string` 依然读得到正文，别的 App 粘贴也不受影响。
    /// 多 item（图片、多文件）时直接放弃 —— 宁可不传数据，也不能毁了用户的剪贴板。
    private static func writePasteboard(_ data: Data) {
        let pb = UIPasteboard.general
        let items = pb.items
        if items.count == 1 {
            var item = items[0]
            item[pbType] = data
            pb.items = [item]
        } else if items.isEmpty {
            pb.items = [[pbType: data]]
        }
    }

    private static func groupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}
