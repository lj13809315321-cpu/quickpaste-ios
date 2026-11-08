package app.mulberry6323.quickpaste;

import org.json.JSONObject;

/** 一条来自电脑端 v1.6 同步服务的记录，字段与 sync/server.js 的 addItem() 一致。 */
public final class SyncItem {

    public final String id;
    public final String text;
    public final String type;
    public final String image;   // base64（不含 data: 前缀）
    public final String mime;
    public final String source;  // pc / copyq -> 💻, phone -> 📱
    public final long ts;

    public SyncItem(String id, String text, String type, String image,
                    String mime, String source, long ts) {
        this.id = id == null ? "" : id;
        this.text = text == null ? "" : text;
        this.type = type == null ? "text" : type;
        this.image = image == null ? "" : image;
        this.mime = mime == null || mime.isEmpty() ? "image/png" : mime;
        this.source = source == null ? "pc" : source;
        this.ts = ts;
    }

    public static SyncItem from(JSONObject o) {
        if (o == null) return null;
        return new SyncItem(
                o.optString("id", ""),
                o.optString("text", ""),
                o.optString("type", "text"),
                o.optString("image", ""),
                o.optString("mime", "image/png"),
                o.optString("source", "pc"),
                o.optLong("ts", 0L));
    }

    public boolean isImage() {
        return "image".equals(type) && !image.isEmpty();
    }

    public boolean fromPhone() {
        return "phone".equals(source);
    }

    /** 本机复制历史（键盘直接读系统剪贴板收录，不依赖电脑端服务） */
    public boolean isLocal() {
        return "local".equals(source);
    }

    /** 列表上显示的文字：折叠空白，空内容给占位符。 */
    public String displayText() {
        String t = text.replaceAll("\\s+", " ").trim();
        return t.isEmpty() ? "（空白内容）" : t;
    }
}
