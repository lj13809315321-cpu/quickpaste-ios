package app.mulberry6323.quickpaste;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.List;

/**
 * 电脑端 v1.6 同步服务的 HTTP 客户端。
 * - GET  /api/items?limit=30   拉取剪贴板列表（文字 + 图片）
 * - POST /api/items            发送文字 {"text":..,"source":"phone","pair":..}
 * - POST /api/image            发送图片二进制 body（LocalSend 风格）
 * - DELETE /api/items?id=..    删除单条；不带 id 清空
 * 全部为阻塞调用，调用方必须放在后台线程。
 */
public final class SyncClient {

    public static final class Result {
        public boolean ok;
        public int count;
        public long serverTime;
        public String backend = "";
        public final List<SyncItem> items = new ArrayList<SyncItem>();
    }

    private static final int TIMEOUT = 3500;
    private final String base;
    private final String pair;

    public SyncClient(String url, String pair) {
        String u = url == null ? "" : url.trim();
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        this.base = u;
        this.pair = pair == null ? "" : pair.trim();
    }

    public String base() {
        return base;
    }

    private HttpURLConnection conn(String path, String method) throws Exception {
        if (base.isEmpty()) throw new Exception("未设置电脑地址");
        HttpURLConnection c = (HttpURLConnection) new URL(base + path).openConnection();
        c.setRequestMethod(method);
        c.setConnectTimeout(TIMEOUT);
        c.setReadTimeout(TIMEOUT);
        c.setUseCaches(false);
        c.setRequestProperty("Accept", "application/json");
        if (!pair.isEmpty()) c.setRequestProperty("X-Pair-Code", pair);
        return c;
    }

    private static String readAll(InputStream in) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
        return new String(bos.toByteArray(), "UTF-8");
    }

    private static void requireOk(HttpURLConnection c) throws Exception {
        int code = c.getResponseCode();
        InputStream stream = code >= 200 && code < 300 ? c.getInputStream() : c.getErrorStream();
        String body = stream == null ? "" : readAll(stream);
        c.disconnect();
        if (code < 200 || code >= 300) throw new Exception("HTTP " + code + " " + body);
        if (!body.isEmpty() && body.trim().startsWith("{")) {
            JSONObject o = new JSONObject(body);
            if (o.has("ok") && !o.optBoolean("ok", true)) {
                throw new Exception(o.optString("error", "服务返回失败"));
            }
        }
    }

    /** 拉取列表。limit 由服务端限制在 1..100。 */
    public Result fetch(int limit) throws Exception {
        HttpURLConnection c = conn("/api/items?limit=" + limit, "GET");
        int code = c.getResponseCode();
        if (code < 200 || code >= 300) {
            c.disconnect();
            throw new Exception("HTTP " + code);
        }
        String body = readAll(c.getInputStream());
        c.disconnect();

        JSONObject o = new JSONObject(body);
        Result r = new Result();
        r.ok = o.optBoolean("ok", true);
        r.count = o.optInt("count", 0);
        r.serverTime = o.optLong("serverTime", 0L);
        r.backend = o.optString("backend", "");
        JSONArray arr = o.optJSONArray("items");
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                SyncItem it = SyncItem.from(arr.optJSONObject(i));
                if (it != null) r.items.add(it);
            }
        }
        return r;
    }

    /** 手机 -> 电脑：文字。 */
    public void pushText(String text) throws Exception {
        JSONObject o = new JSONObject();
        o.put("text", text);
        o.put("source", "phone");
        if (!pair.isEmpty()) o.put("pair", pair);
        HttpURLConnection c = conn("/api/items", "POST");
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        byte[] data = o.toString().getBytes("UTF-8");
        c.setFixedLengthStreamingMode(data.length);
        OutputStream os = c.getOutputStream();
        os.write(data);
        os.flush();
        os.close();
        requireOk(c);
    }

    /** 手机 -> 电脑：图片二进制直传，不包 base64 JSON。 */
    public void pushImage(byte[] data, String mime) throws Exception {
        if (mime == null || mime.isEmpty()) mime = "image/png";
        String q = "/api/image?source=phone&mime=" + URLEncoder.encode(mime, "UTF-8");
        if (!pair.isEmpty()) q += "&pair=" + URLEncoder.encode(pair, "UTF-8");
        HttpURLConnection c = conn(q, "POST");
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", mime);
        c.setFixedLengthStreamingMode(data.length);
        OutputStream os = c.getOutputStream();
        os.write(data);
        os.flush();
        os.close();
        requireOk(c);
    }

    public void delete(String id) throws Exception {
        String path = "/api/items";
        if (id != null && !id.isEmpty()) {
            path += "?id=" + URLEncoder.encode(id, "UTF-8");
        }
        HttpURLConnection c = conn(path, "DELETE");
        requireOk(c);
    }
}
