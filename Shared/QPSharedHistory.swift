import Foundation
import UIKit

/// 主 App（系统画中画 PiP 后台监听）↔ 键盘扩展 之间的「连续复制」数据通道。
///
/// 为什么需要它：iOS 键盘扩展在键盘收起后会被系统挂起，没法在别的 App 里
/// 常驻监听剪贴板；真正能跨 App 连续复制的是主 App 的 PiP 小窗（PiP 期间
/// App 保持运行）。主 App 抓到的内容必须能回到键盘列表里显示。
///
/// 两级通道，按签名环境自动选择，不需要额外 entitlement 也不会崩：
///   1. App Group 共享容器 —— 若手机端签名工具给主 App 和键盘扩展都开了
///      group.app.mulberry6323.twilight7904，直接读写共享 JSON，最干净。
///   2. UIPasteboard.general 的一个自定义 item —— 零 entitlement 的兜底。
///      只追加一个带自定义 UTI 的 item，用户复制的文本 item 原样保留，
///      其它 App 读 .string 时完全不受影响；每次写入会先清掉自己上一次的 item。
///
/// 键盘扩展只读不写，避免键盘自己改动系统剪贴板。
enum QPSharedHistory {

    struct Payload: Codable {
        var items: [String] = []
        var pip: Bool = false
    }

    static let groupID = "group.app.mulberry6323.twilight7904"
    private static let pbType = "app.mulberry6323.qp.capture"
    private static let fileName = "qp-shared-history.json"
    private static let maxItems = 30

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

    private static func readPasteboard() -> Payload? {
        for item in UIPasteboard.general.items {
            guard let data = item[pbType] as? Data else { continue }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }
        return nil
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

    static func clear() {
        var p = read()
        p.items = []
        write(p)
    }

    private static func write(_ p: Payload) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        if let url = groupURL() {
            try? data.write(to: url.appendingPathComponent(fileName), options: .atomic)
            return
        }
        writePasteboard(data)
    }

    /// 保留用户复制的所有 item，只替换我们自己那一个自定义 item。
    private static func writePasteboard(_ data: Data) {
        var items = UIPasteboard.general.items.filter { $0[pbType] == nil }
        items.append([pbType: data])
        UIPasteboard.general.items = items
    }

    private static func groupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}
