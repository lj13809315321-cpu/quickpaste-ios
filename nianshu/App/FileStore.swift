import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - 粘鼠 · 文件中转仓库（任意格式）
//
// 为什么需要它：iOS 剪贴板（UIPasteboard）不是文件传输通道。
//   · 源 App 复制「图片 / PDF / HTML」时，有些会把文件字节直接放进剪贴板 → 能自动抓；
//   · 复制「视频 / PSD / PPT / WPS 表格 / Word」时，绝大多数 App 只放一个
//     public.file-url（指向源 App 沙盒，粘鼠没有权限打开）或一个文件名 → 抓不到字节。
// 所以除「剪贴板自动抓取」外，再给一条系统文件通道：用户在 App 内用
// .fileImporter 从「文件」App 导入任意文件，粘鼠存进自己沙盒，再用系统分享面板
// （UIActivityViewController）发到微信 / WPS / 任意目标 App。这条路覆盖全部格式，
// 且不需要 Share Extension / App Group，保持单 target、不影响手机端自签。

struct FileMeta: Codable, Identifiable, Hashable {
    var id: String        // 数据 sha256，天然去重
    var name: String      // 展示名（含扩展名）
    var uti: String       // 原始 UTI（回贴剪贴板时用）
    var diskName: String  // 沙盒内的实际文件名
    var size: Int64
    var ts: Double
}

enum FileStore {

    private static let metaKey = "ns.files.v1"

    /// 剪贴板自动收录单项上限：超过 20MB 不自动抓（大视频走「导入文件」）。
    /// 系统剪贴板 server 对超大二进制不可靠，硬收会拖慢甚至失败。
    static let maxAutoBytes = 20 * 1024 * 1024
    /// 导入文件单项上限：50MB（再大请用系统「文件」App 直接分享）。
    static let maxImportBytes = 50 * 1024 * 1024
    /// 仓库最多保留文件数。
    private static let maxFiles = 100

    /// 剪贴板自动收录白名单：UTI → 扩展名。
    /// 只收「源 App 真把文件字节放进剪贴板」的类型；图片由 .image、纯文本由
    /// .string 单独处理，故这两类不在此表，避免重复收录。
    /// 办公文档/PSD 等多数 App 只给 file-url，这里读不到 Data 就自然跳过。
    static let autoCaptureUTIs: [String: String] = [
        "com.adobe.pdf": "pdf",
        "public.html": "html",
        "public.rtf": "rtf",
        "public.xml": "xml",
        "public.json": "json",
        "public.csv": "csv",
        "public.zip-archive": "zip",
        "public.mpeg-4": "mp4",
        "com.apple.quicktime-movie": "mov",
        "public.mp3": "mp3",
        "public.mpeg-4-audio": "m4a",
        "com.microsoft.waveform-audio": "wav",
        "com.microsoft.word.doc": "doc",
        "org.openxmlformats.wordprocessingml.document": "docx",
        "com.microsoft.excel.xls": "xls",
        "org.openxmlformats.spreadsheetml.sheet": "xlsx",
        "com.microsoft.powerpoint.ppt": "ppt",
        "org.openxmlformats.presentationml.presentation": "pptx",
        "com.adobe.photoshop-image": "psd",
        // 图片类（png/jpeg/tiff/gif）已由 UIPasteboard.image 收录，这里不再重复；
        // SVG 系统不给 .image，保留自动收录。
        "public.svg-image": "svg"
    ]

    // MARK: - 目录 / 元数据

    static func dir() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ns_files", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func load() -> [FileMeta] {
        guard let d = UserDefaults.standard.data(forKey: metaKey),
              let a = try? JSONDecoder().decode([FileMeta].self, from: d) else { return [] }
        return a
    }

    private static func saveMeta(_ a: [FileMeta]) {
        if let d = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(d, forKey: metaKey)
        }
    }

    static func all() -> [FileMeta] {
        load().sorted { $0.ts > $1.ts }
    }

    static func url(for m: FileMeta) -> URL {
        dir().appendingPathComponent(m.diskName)
    }

    // MARK: - 存文件

    /// 存一份文件字节。按数据 sha256 去重（回贴自身不会被重复收录）。
    /// 返回 true 表示确实是新文件。
    @discardableResult
    static func save(data: Data, uti: String, suggestedName: String?, limit: Int) -> Bool {
        guard !data.isEmpty, data.count <= limit else { return false }
        let hash = data.sha256String()
        var a = load()
        if a.contains(where: { $0.id == hash }) { return false }
        let ext: String = {
            if let e = autoCaptureUTIs[uti] { return e }
            if let s = suggestedName {
                let pe = NSString(string: s).pathExtension
                if !pe.isEmpty { return pe }
            }
            return "dat"
        }()
        let baseName: String = {
            guard let s = suggestedName, !s.isEmpty else { return "文件" }
            return NSString(string: s).deletingPathExtension
        }()
        let disk = hash + "." + ext
        do {
            try data.write(to: dir().appendingPathComponent(disk), options: .atomic)
        } catch { return false }
        let display = (suggestedName?.isEmpty == false) ? suggestedName! : "\(baseName).\(ext)"
        let meta = FileMeta(id: hash, name: display, uti: uti, diskName: disk,
                            size: Int64(data.count), ts: Date().timeIntervalSince1970)
        a.insert(meta, at: 0)
        if a.count > maxFiles {
            for m in a.suffix(from: maxFiles) {
                try? FileManager.default.removeItem(at: dir().appendingPathComponent(m.diskName))
            }
            a = Array(a.prefix(maxFiles))
        }
        saveMeta(a)
        return true
    }

    /// 从「文件」App 导入（.fileImporter 给的是 security-scoped URL）。
    /// 返回新导入的文件数。
    static func importFiles(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else { continue }
            let ext = u.pathExtension
            let uti = UTType(filenameExtension: ext)?.identifier ?? "public.data"
            if save(data: d, uti: uti, suggestedName: u.lastPathComponent,
                    limit: maxImportBytes) { n += 1 }
        }
        return n
    }

    /// 扫 UIPasteboard.items，把白名单 UTI 的文件字节收进仓库。
    /// 返回新收录条数。图片/纯文本不在此表，不会和 .image/.string 重复。
    @discardableResult
    static func capture(from pb: UIPasteboard) -> Int {
        var n = 0
        for item in pb.items {
            for (uti, value) in item {
                guard let ext = autoCaptureUTIs[uti] else { continue }
                let d: Data?
                if let raw = value as? Data { d = raw }
                else if let s = value as? String { d = s.data(using: .utf8) }
                else { d = nil }
                guard let data = d, !data.isEmpty, data.count <= maxAutoBytes else { continue }
                if save(data: data, uti: uti, suggestedName: "剪贴板文件.\(ext)",
                        limit: maxAutoBytes) { n += 1 }
            }
        }
        return n
    }

    static func delete(_ ids: [String]) {
        let set = Set(ids)
        let a = load()
        for m in a where set.contains(m.id) {
            try? FileManager.default.removeItem(at: dir().appendingPathComponent(m.diskName))
        }
        saveMeta(a.filter { !set.contains($0.id) })
    }

    // MARK: - 展示辅助

    static func sizeLabel(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d < 1024 { return "\(bytes) B" }
        if d < 1024 * 1024 { return String(format: "%.1f KB", d / 1024) }
        return String(format: "%.1f MB", d / 1024 / 1024)
    }

    static func icon(for name: String) -> String {
        let e = NSString(string: name).pathExtension.lowercased()
        switch e {
        case "pdf": return "doc.richtext"
        case "html", "htm", "xml", "json", "svg": return "chevron.left.forwardslash.chevron.right"
        case "txt", "rtf", "csv", "md": return "doc.plaintext"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "m4a", "wav": return "waveform"
        case "psd", "tiff", "gif": return "photo.stack"
        case "doc", "docx", "wps": return "doc.text"
        case "xls", "xlsx", "et": return "tablecells"
        case "ppt", "pptx", "dps": return "rectangle.on.rectangle"
        case "zip", "rar", "7z": return "doc.zipper"
        default: return "doc"
        }
    }

    static func timeLabel(_ ts: Double) -> String {
        let d = Date().timeIntervalSince1970 - ts
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
