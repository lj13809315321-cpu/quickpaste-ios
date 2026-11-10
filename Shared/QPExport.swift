import UIKit

// MARK: - v1.8.14 主 App「连续复制」页导出工具
//
// 纯函数：条目文本 → 临时文件 URL（或图片 Data），交给系统分享面板。
// 键盘扩展侧有一套自己的导出实现（发到电脑），这套面向「导出成文件分享」，
// 放 Shared 里两边都能用；函数名与键盘侧不冲突。

enum QPExport {

    /// 时间戳（文件名用）
    private static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 条目拼接头部
    private static func head(_ count: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "QuickPaste 连续复制导出（\(f.string(from: Date()))，共 \(count) 条）"
    }

    // MARK: 文本类

    static func txtText(_ items: [String]) -> String {
        head(items.count) + "\n\n" + items.joined(separator: "\n\n————\n\n")
    }

    static func csvText(_ items: [String]) -> String {
        // 带 BOM，Excel/WPS 直接打开中文不乱码
        var rows = ["序号,内容,字符数"]
        for (i, s) in items.enumerated() {
            let cell = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
            rows.append("\(i + 1),\(cell),\(s.count)")
        }
        return "\u{FEFF}" + rows.joined(separator: "\r\n")
    }

    static func htmlText(_ items: [String]) -> String {
        var body = ""
        for (i, s) in items.enumerated() {
            let esc = s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            body += "<li><p><b>#\(i + 1)</b></p><p>\(esc.replacingOccurrences(of: "\n", with: "<br>"))</p></li>"
        }
        return """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <title>\(head(items.count))</title>
        <style>body{font-family:-apple-system,'PingFang SC';max-width:720px;margin:24px auto;color:#222}
        li{margin:14px 0;padding:10px 14px;background:#f6f6f8;border-radius:10px}
        p{margin:4px 0}</style></head><body>
        <h2>\(head(items.count))</h2><ol>\(body)</ol></body></html>
        """
    }

    /// Word(.doc)：HTML 加 Office 命名空间，Word/WPS 直接打开
    static func wordText(_ items: [String]) -> String {
        let html = htmlText(items)
        let ns = "xmlns:o='urn:schemas-microsoft-com:office:office' "
            + "xmlns:w='urn:schemas-microsoft-com:office:word' "
            + "xmlns='http://www.w3.org/TR/REC-html40'>"
        if let r = html.range(of: ">") {
            return String(html[..<r.lowerBound]) + " " + ns + String(html[r.upperBound...])
        }
        return html
    }

    // MARK: 文件落盘

    @discardableResult
    static func writeTemp(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url }
        catch { return nil }
    }

    static func txtFile(_ items: [String]) -> URL? {
        writeTemp(Data(txtText(items).utf8), name: "QuickPaste-连续复制-\(stamp).txt")
    }

    static func csvFile(_ items: [String]) -> URL? {
        writeTemp(Data(csvText(items).utf8), name: "QuickPaste-连续复制-\(stamp).csv")
    }

    static func htmlFile(_ items: [String]) -> URL? {
        writeTemp(Data(htmlText(items).utf8), name: "QuickPaste-连续复制-\(stamp).html")
    }

    static func wordFile(_ items: [String]) -> URL? {
        writeTemp(Data(wordText(items).utf8), name: "QuickPaste-连续复制-\(stamp).doc")
    }

    // MARK: PDF（A4 分页，与键盘侧同一规则：每页按行排，页高有下界）

    static func pdfFile(_ items: [String]) -> URL? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "QuickPaste 连续复制导出（\(fmt.string(from: Date()))，共 \(items.count) 条）"

        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4 72dpi
        let margin: CGFloat = 40
        let contentW = pageRect.width - margin * 2
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        let bodyFont = UIFont.systemFont(ofSize: 11.5)
        let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)

        var lines: [(String, UIFont, UIColor)] = [(title, titleFont, .black)]
        for (i, s) in items.enumerated() {
            lines.append(("#\(i + 1)", UIFont.systemFont(ofSize: 11, weight: .semibold),
                          UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)))
            for raw in s.components(separatedBy: "\n") {
                var seg = raw.isEmpty ? " " : raw
                // 长行按宽度软折行（CTFrame 不用，直接测量截断到合理段长）
                while measure(seg, font: bodyFont, width: contentW) > contentW && seg.count > 8 {
                    let cut = binaryCut(seg, font: bodyFont, width: contentW)
                    lines.append((String(seg[..<cut]), bodyFont, .darkGray))
                    seg = String(seg[cut...])
                }
                lines.append((seg, bodyFont, .darkGray))
            }
            lines.append(("————", bodyFont, .lightGray))
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            var y: CGFloat = 0
            var page = 0
            func newPage() {
                ctx.beginPage()
                page += 1
                y = margin
            }
            newPage()
            for (text, font, color) in lines {
                let h = ceil(measure(text, font: font, width: contentW) /
                             max(contentW, 1)) * font.lineHeight + 4
                if y + h > pageRect.height - margin { newPage() }
                text.draw(at: CGPoint(x: margin, y: y), withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: para
                ])
                y += h
            }
            _ = page
        }
        return writeTemp(data, name: "QuickPaste-连续复制-\(stamp).pdf")
    }

    private static func measure(_ s: String, font: UIFont, width: CGFloat) -> CGFloat {
        (s as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font], context: nil).width
    }

    /// 找到宽度刚好装下的最大前缀（二分）
    private static func binaryCut(_ s: String, font: UIFont, width: CGFloat) -> String.Index {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi {
            let mid = s.index(lo, offsetBy: s.distance(from: lo, to: hi) / 2 + 1, limitedBy: hi) ?? hi
            if measure(String(s[..<mid]), font: font, width: width) <= width { lo = mid } else { hi = s.index(before: mid) }
        }
        return lo
    }

    // MARK: 图片（白底长图，宽 640pt @2x）

    static func imageFile(_ items: [String]) -> URL? {
        let text = txtText(items)
        let scale: CGFloat = 2
        let width: CGFloat = 640
        let font = UIFont.systemFont(ofSize: 14)
        let titleFont = UIFont.systemFont(ofSize: 20, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6

        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.black]
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.darkGray,
                                                       .paragraphStyle: para]
        let bodyRect = (text as NSString).boundingRect(
            with: CGSize(width: width - 48, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: bodyAttr, context: nil)
        let titleH: CGFloat = 44
        let height = ceil(bodyRect.height) + titleH + 64
        let size = CGSize(width: width * scale, height: height * scale)

        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            let headStr = head(items.count)
            headStr.draw(at: CGPoint(x: 24 * scale, y: 24 * scale), withAttributes: titleAttr)
            (text as NSString).draw(
                with: CGRect(x: 24 * scale, y: titleH * scale, width: (width - 48) * scale,
                             height: bodyRect.height * scale + 40),
                options: [.usesLineFragmentOrigin], attributes: bodyAttr, context: nil)
        }
        guard let png = img.pngData() else { return nil }
        return writeTemp(png, name: "QuickPaste-连续复制-\(stamp).png")
    }
}
