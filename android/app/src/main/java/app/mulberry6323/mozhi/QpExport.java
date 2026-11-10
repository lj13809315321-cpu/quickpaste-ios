package app.mulberry6323.mozhi;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * v1.8.15 新增：把剪贴板记录导出为文件，供分享 / 保存到手机。
 * 纯 Java 实现，不依赖任何第三方库：
 *   - txt  / csv 直接写文本
 *   - xlsx 用 java.util.zip 手写 Office Open XML（inlineStr 内联字符串）
 * 文件写到 cache/qp_export/，由 QpImageProvider 以 content:// 暴露给其它 App。
 */
public final class QpExport {

    public static File exportDir(Context ctx) {
        File d = new File(ctx.getCacheDir(), "qp_export");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /** format: "txt" | "csv" | "xlsx"。返回生成的文件。 */
    public static File write(Context ctx, List<String> texts, String format) throws Exception {
        File dir = exportDir(ctx);
        if ("csv".equals(format)) {
            File f = new File(dir, "mozhi_clipboard.csv");
            writeCsv(f, texts);
            return f;
        } else if ("xlsx".equals(format)) {
            File f = new File(dir, "mozhi_clipboard.xlsx");
            byte[] data = xlsxData(texts);
            FileOutputStream os = new FileOutputStream(f);
            os.write(data);
            os.close();
            return f;
        } else {
            File f = new File(dir, "mozhi_clipboard.txt");
            StringBuilder sb = new StringBuilder();
            for (String t : texts) sb.append(t == null ? "" : t).append("\n");
            FileOutputStream os = new FileOutputStream(f);
            os.write(sb.toString().getBytes("UTF-8"));
            os.close();
            return f;
        }
    }

    // --------------------------------------------------------------- CSV

    private static void writeCsv(File f, List<String> texts) throws Exception {
        StringBuilder sb = new StringBuilder();
        sb.append("﻿"); // UTF-8 BOM，Excel 才能正确识别中文
        sb.append("序号,内容\n");
        for (int i = 0; i < texts.size(); i++) {
            String s = texts.get(i) == null ? "" : texts.get(i);
            if (s.indexOf('"') >= 0 || s.indexOf(',') >= 0
                    || s.indexOf('\n') >= 0 || s.indexOf('\r') >= 0) {
                s = "\"" + s.replace("\"", "\"\"") + "\"";
            }
            sb.append(i + 1).append(",").append(s).append("\n");
        }
        FileOutputStream os = new FileOutputStream(f);
        os.write(sb.toString().getBytes("UTF-8"));
        os.close();
    }

    // --------------------------------------------------------------- XLSX

    private static byte[] xlsxData(List<String> texts) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        ZipOutputStream zos = new ZipOutputStream(bos);

        put(zos, "[Content_Types].xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
                "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
                "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
                "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" +
                "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>" +
                "</Types>");

        put(zos, "_rels/.rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>" +
                "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>" +
                "</Relationships>");

        put(zos, "docProps/core.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" " +
                "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" " +
                "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
                "<dc:title>墨指 剪贴板</dc:title><dc:creator>墨指</dc:creator>" +
                "</cp:coreProperties>");

        put(zos, "xl/workbook.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" " +
                "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" +
                "<sheets><sheet name=\"剪贴板\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>");

        put(zos, "xl/_rels/workbook.xml.rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                "</Relationships>");

        StringBuilder sheet = new StringBuilder();
        sheet.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        sheet.append("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n");
        sheet.append("<sheetData>\n");
        sheet.append("<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>序号</t></is></c>" +
                "<c r=\"B1\" t=\"inlineStr\"><is><t>内容</t></is></c></row>\n");
        for (int i = 0; i < texts.size(); i++) {
            int row = i + 2;
            sheet.append("<row r=\"").append(row).append("\">");
            sheet.append("<c r=\"A").append(row).append("\"><v>").append(i + 1).append("</v></c>");
            sheet.append("<c r=\"B").append(row).append("\" t=\"inlineStr\"><is><t>")
                    .append(xescape(texts.get(i))).append("</t></is></c>");
            sheet.append("</row>\n");
        }
        sheet.append("</sheetData>\n</worksheet>");
        put(zos, "xl/worksheets/sheet1.xml", sheet.toString());

        zos.close();
        return bos.toByteArray();
    }

    private static void put(ZipOutputStream zos, String name, String content) throws Exception {
        ZipEntry e = new ZipEntry(name);
        zos.putNextEntry(e);
        byte[] data = content.getBytes("UTF-8");
        zos.write(data);
        zos.closeEntry();
    }

    /** XML 转义 + 过滤非法控制字符（Excel 不接受）。 */
    private static String xescape(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '&') b.append("&amp;");
            else if (c == '<') b.append("&lt;");
            else if (c == '>') b.append("&gt;");
            else if (c == '"') b.append("&quot;");
            else if (c == '\'') b.append("&apos;");
            else if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') b.append(' ');
            else b.append(c);
        }
        return b.toString();
    }
}
