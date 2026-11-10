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

        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
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

    // MARK: Excel（.xlsx，手写 stored-ZIP + Office Open XML，无第三方依赖）

    private static func u16(_ v: UInt16) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 2)
    }
    private static func u32(_ v: UInt32) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 4)
    }

    /// CRC32（IEEE），用于 ZIP 校验。
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : (crc >> 1)
            }
        }
        return ~crc
    }

    /// 把多个（文件名, 数据）打包成 **store（不压缩）** 的 ZIP。
    /// 不压缩最稳：不需要 deflate，iOS 自带解压（Excel/系统）都能读。
    private static func zipStored(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offset = 0
        for f in files {
            let crc = crc32(f.data)
            let size = UInt32(f.data.count)
            let nameBytes = Data(f.name.utf8)

            var lh = Data()
            lh.append(u32(0x04034b50))   // 本地文件头签名
            lh.append(u16(20))           // 解压所需版本
            lh.append(u16(0))            // 通用标志
            lh.append(u16(0))            // 压缩方式 0 = store
            lh.append(u16(0))            // 最后修改时间
            lh.append(u16(0))            // 最后修改日期
            lh.append(u32(crc))
            lh.append(u32(size))
            lh.append(u32(size))
            lh.append(u16(UInt16(nameBytes.count)))
            lh.append(u16(0))            // 扩展字段长度
            lh.append(nameBytes)
            lh.append(f.data)
            out.append(lh)

            var cd = Data()
            cd.append(u32(0x02014b50))   // 中央目录头签名
            cd.append(u16(20))           // 版本（由）
            cd.append(u16(20))           // 版本（需）
            cd.append(u16(0))
            cd.append(u16(0))
            cd.append(u16(0))
            cd.append(u16(0))
            cd.append(u32(crc))
            cd.append(u32(size))
            cd.append(u32(size))
            cd.append(u16(UInt16(nameBytes.count)))
            cd.append(u16(0))            // 扩展字段
            cd.append(u16(0))            // 注释
            cd.append(u16(0))            // 磁盘号
            cd.append(u16(0))            // 内部属性
            cd.append(u32(0))            // 外部属性
            cd.append(u32(UInt32(offset)))
            cd.append(nameBytes)
            central.append(cd)

            offset += lh.count
        }
        let centralStart = offset
        out.append(central)
        var eocd = Data()
        eocd.append(u32(0x06054b50))     // 中央目录结束签名
        eocd.append(u16(0))
        eocd.append(u16(0))
        eocd.append(u16(UInt16(files.count)))
        eocd.append(u16(UInt16(files.count)))
        eocd.append(u32(UInt32(central.count)))
        eocd.append(u32(UInt32(centralStart)))
        eocd.append(u16(0))
        out.append(eocd)
        return out
    }

    private static func xlsxEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 生成真正的 .xlsx（每一条占一行，A 列存文本；用 inlineStr 内联字符串，中文不乱码）。
    static func xlsxData(_ items: [String]) -> Data? {
        var rows = ""
        for (i, s) in items.enumerated() {
            let cell = "<c r=\"A\(i + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xlsxEscape(s))</t></is></c>"
            rows += "<row r=\"\(i + 1)\">\(cell)</row>"
        }
        let sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<sheetData>\(rows)</sheetData></worksheet>"
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            + "</Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>"
        let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<sheets><sheet name=\"剪贴板\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            + "</Relationships>"

        let files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(wbRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        ]
        return zipStored(files)
    }

    static func xlsxFile(_ items: [String]) -> URL? {
        guard let d = xlsxData(items) else { return nil }
        return writeTemp(d, name: "QuickPaste-连续复制-\(stamp).xlsx")
    }
}
