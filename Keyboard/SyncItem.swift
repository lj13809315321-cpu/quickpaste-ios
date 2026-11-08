import Foundation

/// 一条来自电脑端 v1.6 同步服务的记录，字段与 sync/server.js 的 addItem() 一致。
struct SyncItem {
    let id: String
    let text: String
    let type: String
    let image: String          // base64（不含 data: 前缀）
    let mime: String
    let source: String         // pc / copyq -> 💻, phone -> 📱
    let ts: Double

    var isImage: Bool { type == "image" && !image.isEmpty }
    var fromPhone: Bool { source == "phone" }
    /// 本机复制历史（键盘扩展直接读系统剪贴板收录，不依赖电脑端服务）
    var isLocal: Bool { source == "local" }

    var displayText: String {
        let t = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return t.isEmpty ? "（空白内容）" : t
    }

    static func from(_ dict: [String: Any]) -> SyncItem {
        SyncItem(
            id: dict["id"] as? String ?? "",
            text: dict["text"] as? String ?? "",
            type: dict["type"] as? String ?? "text",
            image: dict["image"] as? String ?? "",
            mime: dict["mime"] as? String ?? "image/png",
            source: dict["source"] as? String ?? "pc",
            ts: (dict["ts"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    var imageData: Data? { Data(base64Encoded: image) }
}
